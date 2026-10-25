//go:build !android

package tun

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"

	"github.com/miekg/dns"
	tun "github.com/mythologyli/sing-tun"
	"github.com/mythologyli/zju-connect/client"
	"github.com/mythologyli/zju-connect/internal/hook_func"
	"github.com/mythologyli/zju-connect/internal/ippool"
	"github.com/mythologyli/zju-connect/internal/ipresource"
	"github.com/mythologyli/zju-connect/internal/zcdns"
	"github.com/mythologyli/zju-connect/internal/zctcpip"
	"github.com/mythologyli/zju-connect/log"
	"github.com/mythologyli/zju-connect/resolve"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	gvisorstack "gvisor.dev/gvisor/pkg/tcpip/stack"
)

const MTU uint32 = 1400
const maxInboundPacketSize = 1500

type Stack struct {
	endpoint            *Endpoint
	tcpListenerEndpoint *TCPListenerEndpoint
	tcpListenerStack    *gvisorstack.Stack
	l3Conn              io.ReadWriteCloser
	resolve             zcdns.LocalServer
	ipResources         []client.IPResource
	resourceIndexOnce   sync.Once
	resourceIndex       *ipresource.Index
	resourceCache       *resourceDecisionCache
	ipPool              *ippool.IPPool[[]client.DomainResource]
	fakeIP              bool
}

func (s *Stack) SetupResolve(r zcdns.LocalServer) {
	s.resolve = r
}

func (s *Stack) SetupIPPool(ipPool *ippool.IPPool[[]client.DomainResource]) {
	s.ipPool = ipPool
}

// Prepare establishes the transport before the caller announces tunnel readiness.
func (s *Stack) Prepare() error {
	if s.l3Conn != nil {
		return nil
	}
	var err error
	s.l3Conn, err = s.endpoint.client.NewL3Conn()
	return err
}

// Run preserves the upstream CLI entry point while supervised callers use RunContext.
func (s *Stack) Run() {
	if err := s.RunContext(context.Background()); err != nil && !hook_func.IsTerminal() {
		panic(err)
	}
}

// RunContext stops both packet pumps together and returns transport failures to the supervisor.
func (s *Stack) RunContext(ctx context.Context) error {
	if s.endpoint.client.CanUseTCPTunnel() {
		if err := s.CreateTCPListener(); err != nil {
			return err
		}
		s.StartTCPListener()
	}
	if err := s.Prepare(); err != nil {
		return err
	}
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var closeOnce sync.Once
	closeIO := func() {
		closeOnce.Do(func() {
			if closer, ok := s.endpoint.client.(interface{ Close() }); ok {
				closer.Close()
			}
			_ = s.l3Conn.Close()
			_ = s.endpoint.ifce.Close()
		})
	}
	stopClose := context.AfterFunc(runCtx, closeIO)
	defer stopClose()
	receiveDone := make(chan struct{})
	receiveError := make(chan error, 1)
	go func() {
		defer close(receiveDone)
		defer cancel()
		buf := make([]byte, maxInboundPacketSize+tun.PacketOffset)
		for {
			n, err := s.l3Conn.Read(buf)
			if err != nil {
				receiveError <- err
				return
			}
			if n == 0 {
				receiveError <- io.ErrNoProgress
				return
			}
			if err = s.endpoint.Write(buf[:n]); err != nil {
				receiveError <- err
				return
			}
		}
	}()
	defer func() { cancel(); closeIO(); <-receiveDone }()
	buf := make([]byte, MTU+tun.PacketOffset)
	for {
		n, err := s.endpoint.Read(buf)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			select {
			case receiveErr := <-receiveError:
				return receiveErr
			default:
				return err
			}
		}
		if n == 0 {
			return io.ErrNoProgress
		}
		if n < zctcpip.IPv4PacketMinLength {
			continue
		}
		packet := buf[tun.PacketOffset:n]
		switch ipVersion := packet[0] >> 4; ipVersion {
		case zctcpip.IPv4Version:
			err = s.processIPV4(packet)
		default:
			continue
		}
		if err != nil {
			var failure *transportError
			if errors.As(err, &failure) {
				return failure.err
			}
			log.DebugPrintf("Error occurred while processing IP packet: %v", err)
		}
	}
}

type transportError struct{ err error }

func (e *transportError) Error() string { return e.err.Error() }
func (e *transportError) Unwrap() error { return e.err }

func (s *Stack) processIPV4(packet zctcpip.IPv4Packet) error {
	protocol := ""
	port := -1
	switch packet.Protocol() {
	case zctcpip.TCP:
		protocol = "tcp"
		port = int(zctcpip.TCPPacket(packet.Payload()).DestinationPort())
	case zctcpip.UDP:
		udpPacket := zctcpip.UDPPacket(packet.Payload())
		if s.shouldHijackUDPDns(packet, udpPacket) {
			newPacket := make(zctcpip.IPv4Packet, len(packet))
			copy(newPacket, packet)
			newUdpPacket := zctcpip.UDPPacket(newPacket.Payload())
			// need to be non-blocking
			go s.doHijackUDPDns(newPacket, newUdpPacket)
			return nil
		}

		protocol = "udp"
		port = int(zctcpip.UDPPacket(packet.Payload()).DestinationPort())
	case zctcpip.ICMP:
		protocol = "icmp"
	default:
		return fmt.Errorf("protocol %d not supported, skip", packet.Protocol())
	}

	domain, resources, ok := s.ipPool.GetDomain(packet.DestinationIP())
	if ok {
		log.DebugPrintf("IP to domain %s", domain)

		if _, matched := client.MatchDomainResource(resources, protocol, port); matched {
			if protocol == "tcp" {
				_, tcpTunnelMatched := client.MatchDomainResourceWhere(resources, protocol, port, func(resource client.DomainResource) bool {
					return !resource.EnableTCPPrefL3
				})
				return s.processIPV4TCP(packet, packet.Payload(), tcpTunnelMatched)
			} else {
				return s.processIPV4UDP(packet, packet.Payload())
			}
		}
	}

	if _, matched := s.matchStaticResource(packet.DestinationIP(), protocol, port); matched {
		if protocol == "icmp" {
			return s.processIPV4ICMP(packet, packet.Payload())
		}
		if protocol == "tcp" {
			_, tcpTunnelMatched := s.resourceIndex.MatchWhere(packet.DestinationIP(), protocol, port, func(resource client.IPResource) bool {
				return !resource.EnableTCPPrefL3
			})
			return s.processIPV4TCP(packet, packet.Payload(), tcpTunnelMatched)
		} else {
			return s.processIPV4UDP(packet, packet.Payload())
		}
	}

	if port != -1 {
		return fmt.Errorf("no VPN resources found for %s:%d, [%s], skip", packet.DestinationIP(), port, protocol)
	} else {
		return fmt.Errorf("no VPN resources found for %s, [%s], skip", packet.DestinationIP(), protocol)
	}
}

func (s *Stack) matchesStaticResource(destination net.IP, protocol string, port int) bool {
	ip, ok := ipresource.IPv4Uint32(destination)
	if !ok {
		return false
	}
	s.resourceIndexOnce.Do(func() {
		s.resourceIndex = ipresource.New(s.ipResources)
		s.resourceCache = newResourceDecisionCache()
	})
	key := resourceDecisionKey{ip: ip, protocol: protocol, port: port}
	if decision, ok := s.resourceCache.get(key); ok {
		return decision
	}
	_, decision := s.resourceIndex.Match(destination, protocol, port)
	s.resourceCache.set(key, decision)
	return decision
}

func (s *Stack) matchStaticResource(destination net.IP, protocol string, port int) (client.IPResource, bool) {
	s.resourceIndexOnce.Do(func() {
		s.resourceIndex = ipresource.New(s.ipResources)
		s.resourceCache = newResourceDecisionCache()
	})
	return s.resourceIndex.Match(destination, protocol, port)
}

func (s *Stack) processIPV4TCP(packet zctcpip.IPv4Packet, tcpPacket zctcpip.TCPPacket, useTCPTunnel bool) error {
	log.DebugPrintf("receive tcp %s:%d -> %s:%d", packet.SourceIP(), tcpPacket.SourcePort(), packet.DestinationIP(), tcpPacket.DestinationPort())

	if !packet.DestinationIP().IsGlobalUnicast() {
		return s.endpoint.Write(packet)
	}

	if useTCPTunnel && s.endpoint.client.CanUseTCPTunnel() {
		pkt := gvisorstack.NewPacketBuffer(gvisorstack.PacketBufferOptions{
			Payload: buffer.MakeWithData(packet),
		})
		defer pkt.DecRef()
		s.tcpListenerEndpoint.dispatcher.DeliverNetworkPacket(ipv4.ProtocolNumber, pkt)
		return nil
	}

	n, err := s.l3Conn.Write(packet)
	if err != nil {
		if errors.Is(err, client.ErrResourceNotFound) {
			return err
		}
		return &transportError{err: err}
	}
	log.DebugPrintf("Send: wrote %d bytes", n)
	log.DebugDumpHex(packet[:n])

	return err
}

func (s *Stack) processIPV4UDP(packet zctcpip.IPv4Packet, udpPacket zctcpip.UDPPacket) error {
	log.DebugPrintf("receive udp %s:%d -> %s:%d", packet.SourceIP(), udpPacket.SourcePort(), packet.DestinationIP(), udpPacket.DestinationPort())

	if !packet.DestinationIP().IsGlobalUnicast() {
		return s.endpoint.Write(packet)
	}

	n, err := s.l3Conn.Write(packet)
	if err != nil {
		if errors.Is(err, client.ErrResourceNotFound) {
			return err
		}
		return &transportError{err: err}
	}
	log.DebugPrintf("Send: wrote %d bytes", n)
	log.DebugDumpHex(packet[:n])

	return err
}

func (s *Stack) processIPV4ICMP(packet zctcpip.IPv4Packet, icmpHeader zctcpip.ICMPPacket) error {
	log.DebugPrintf("receive icmp %s -> %s", packet.SourceIP(), packet.DestinationIP())
	if icmpHeader.Code() != 0 {
		return nil
	}

	n, err := s.l3Conn.Write(packet)
	if err != nil {
		if errors.Is(err, client.ErrResourceNotFound) {
			return err
		}
		return &transportError{err: err}
	}
	log.DebugPrintf("Send: wrote %d bytes", n)
	log.DebugDumpHex(packet[:n])

	return err
}

// only can handle udp dns query!
func (s *Stack) shouldHijackUDPDns(ipHeader zctcpip.IPv4Packet, udpHeader zctcpip.UDPPacket) bool {
	if udpHeader.DestinationPort() != 53 {
		return false
	}
	return s.resolve.CheckDnsHijack(ipHeader.DestinationIP())
}

func (s *Stack) doHijackUDPDns(ipHeader zctcpip.IPv4Packet, udpHeader zctcpip.UDPPacket) {
	log.DebugPrintf("hijack dns %s:%d -> %s:%d", ipHeader.SourceIP(), udpHeader.SourcePort(), ipHeader.DestinationIP(), udpHeader.DestinationPort())
	msg := dns.Msg{}
	if err := msg.Unpack(udpHeader.Payload()); err != nil {
		log.Printf("unpack dns msg error: %v", err)
		return
	}
	ctx := context.Background()
	if s.fakeIP && s.endpoint.client.CanUseTCPTunnel() {
		ctx = context.WithValue(ctx, resolve.ContextKeyFakeIP, true)
	}
	resMsg, err := s.resolve.HandleDnsMsg(ctx, &msg)
	if err != nil {
		log.Printf("hijack dns %s:%d -> %s:%d error: %v", ipHeader.SourceIP(), udpHeader.SourcePort(), ipHeader.DestinationIP(), udpHeader.DestinationPort(), err)
		return
	}

	resByte, err := resMsg.Pack()
	if err != nil {
		log.Printf("pack dns msg error: %v", err)
		return
	}

	totalLen := int(ipHeader.HeaderLen()) + zctcpip.UDPHeaderSize + len(resByte)

	newPacket := make(zctcpip.IPv4Packet, totalLen)
	copy(newPacket, ipHeader[:ipHeader.HeaderLen()])
	newPacket.SetTotalLength(uint16(totalLen))
	newPacket.SetSourceIP(ipHeader.DestinationIP())
	newPacket.SetDestinationIP(ipHeader.SourceIP())

	newUDPHeader := zctcpip.UDPPacket(newPacket.Payload())
	newUDPHeader.SetSourcePort(udpHeader.DestinationPort())
	newUDPHeader.SetDestinationPort(udpHeader.SourcePort())
	newUDPHeader.SetLength(zctcpip.UDPHeaderSize + uint16(len(resByte)))
	copy(newUDPHeader.Payload(), resByte)

	newUDPHeader.ResetChecksum(newPacket.PseudoSum())
	newPacket.ResetChecksum()
	_ = s.endpoint.Write(newPacket)
}
