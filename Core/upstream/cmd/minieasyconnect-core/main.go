//go:build darwin

// miniEasyConnect supervises one EasyConnect TUN session over private JSON pipes.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	stdlog "log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"github.com/mythologyli/zju-connect/client"
	"github.com/mythologyli/zju-connect/client/authchallenge"
	"github.com/mythologyli/zju-connect/client/easyconnect"
	"github.com/mythologyli/zju-connect/internal/hook_func"
	"github.com/mythologyli/zju-connect/log"
	"github.com/mythologyli/zju-connect/resolve"
	"github.com/mythologyli/zju-connect/stack/tun"
	"github.com/mythologyli/zju-connect/underlay"
	"inet.af/netaddr"
)

const localDNSAddress = "127.0.0.1"

type configuration struct {
	ServerHost               string `json:"serverHost"`
	ServerPort               int    `json:"serverPort"`
	Username                 string `json:"username"`
	Password                 string `json:"password"`
	TrustedCertificateSHA256 string `json:"trustedCertificateSHA256,omitempty"`
}

type command struct {
	Version     int            `json:"version"`
	Kind        string         `json:"kind"`
	SessionID   string         `json:"sessionID"`
	Config      *configuration `json:"config,omitempty"`
	ChallengeID string         `json:"challengeID,omitempty"`
	Answer      string         `json:"answer,omitempty"`
}

type event struct {
	Version           int      `json:"version"`
	Kind              string   `json:"kind"`
	SessionID         string   `json:"sessionID"`
	Phase             string   `json:"phase,omitempty"`
	Code              string   `json:"code,omitempty"`
	Message           string   `json:"message,omitempty"`
	InterfaceName     string   `json:"interfaceName,omitempty"`
	DNSAddress        string   `json:"dnsAddress,omitempty"`
	Routes            []string `json:"routes,omitempty"`
	ChallengeID       string   `json:"challengeID,omitempty"`
	ChallengeKind     string   `json:"challengeKind,omitempty"`
	ImageBase64       string   `json:"imageBase64,omitempty"`
	CertificateSHA256 string   `json:"certificateSHA256,omitempty"`
}

type session struct {
	id            string
	ctx           context.Context
	cancel        context.CancelFunc
	out           *json.Encoder
	outMu         sync.Mutex
	configured    chan struct{}
	answerMu      sync.Mutex
	answers       map[string]chan string
	nextChallenge int
}

// main keeps credentials out of arguments, files, logs and inherited environments.
func main() {
	stdlog.SetOutput(io.Discard)
	log.DisableDebug()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	if !scanner.Scan() {
		return
	}
	var first command
	if json.Unmarshal(scanner.Bytes(), &first) != nil || first.Version != 1 || first.Kind != "start" || first.SessionID == "" {
		return
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer cancel()
	s := &session{id: first.SessionID, ctx: ctx, cancel: cancel, out: json.NewEncoder(os.Stdout), configured: make(chan struct{}), answers: make(map[string]chan string)}
	if err := validate(first.Config); err != nil {
		s.emit(event{Kind: "failed", Code: "invalidConfiguration", Message: err.Error()})
		return
	}
	go s.readCommands(scanner)
	err := s.run(*first.Config)
	if err != nil && !errors.Is(err, context.Canceled) {
		code, message := publicError(err)
		s.emit(event{Kind: "failed", Code: code, Message: message})
	}
	s.emit(event{Kind: "stopped"})
}

func validate(c *configuration) error {
	if c == nil || strings.TrimSpace(c.ServerHost) == "" || strings.ContainsAny(c.ServerHost, "/\r\n @") || c.ServerPort < 1 || c.ServerPort > 65535 {
		return errors.New("VPN 地址或端口无效")
	}
	if c.Username == "" || c.Password == "" {
		return errors.New("请输入账号和密码")
	}
	if c.TrustedCertificateSHA256 != "" {
		decoded, err := hex.DecodeString(c.TrustedCertificateSHA256)
		if err != nil || len(decoded) != sha256.Size {
			return errors.New("已保存的证书指纹无效")
		}
	}
	return nil
}

func (s *session) emit(e event) {
	e.Version, e.SessionID = 1, s.id
	s.outMu.Lock()
	err := s.out.Encode(e)
	s.outMu.Unlock()
	if err != nil {
		s.cancel()
	}
}

// readCommands treats pipe closure as loss of the owning supervisor.
func (s *session) readCommands(scanner *bufio.Scanner) {
	defer s.cancel()
	for scanner.Scan() {
		var c command
		if json.Unmarshal(scanner.Bytes(), &c) != nil || c.Version != 1 || c.SessionID != s.id {
			return
		}
		switch c.Kind {
		case "stop":
			return
		case "configure":
			select {
			case s.configured <- struct{}{}:
			case <-s.ctx.Done():
				return
			}
		case "answer":
			s.answerMu.Lock()
			ch := s.answers[c.ChallengeID]
			s.answerMu.Unlock()
			if ch != nil {
				select {
				case ch <- c.Answer:
				default:
				}
			}
		default:
			return
		}
	}
}

func (s *session) ask(kind, message string, image []byte) (string, error) {
	return s.askEvent(event{Kind: "challenge", ChallengeKind: kind, Message: message, ImageBase64: base64.StdEncoding.EncodeToString(image)})
}

func (s *session) askEvent(e event) (string, error) {
	s.answerMu.Lock()
	s.nextChallenge++
	id := fmt.Sprintf("%d", s.nextChallenge)
	ch := make(chan string, 1)
	s.answers[id] = ch
	s.answerMu.Unlock()
	defer func() { s.answerMu.Lock(); delete(s.answers, id); s.answerMu.Unlock() }()
	e.ChallengeID = id
	s.emit(e)
	select {
	case value := <-ch:
		if strings.TrimSpace(value) == "" {
			return "", errors.New("验证码不能为空")
		}
		return value, nil
	case <-s.ctx.Done():
		return "", s.ctx.Err()
	}
}

// run owns all resources for exactly one session; the process is not reused.
func (s *session) run(c configuration) error {
	if os.Geteuid() != 0 {
		return errors.New("administrator permission required")
	}
	dialer, err := underlay.New(underlay.Options{AutoDetect: true})
	if err != nil {
		return fmt.Errorf("underlay: %w", err)
	}
	defer dialer.Close()
	pinnedCertificate, err := s.verifyServerBeforeCredentials(c, dialer)
	if err != nil {
		return err
	}
	vpn := easyconnect.NewClient(easyconnect.Options{
		Server:                  net.JoinHostPort(c.ServerHost, fmt.Sprint(c.ServerPort)),
		Auth:                    easyconnect.AuthOptions{Username: c.Username, Password: c.Password},
		Resources:               easyconnect.ResourceOptions{Fetch: true, IncludeDomains: true},
		UnderlayDialer:          dialer,
		VerifyServerCertificate: true,
		PinnedCertificateSHA256: pinnedCertificate,
		ChallengeHandler: authchallenge.HandlerFuncs{
			Code: func(ch authchallenge.CodeChallenge) (authchallenge.CodeResponse, error) {
				v, e := s.ask("code", "请输入服务端要求的验证码", nil)
				return authchallenge.CodeResponse{Code: v}, e
			},
			TextCaptcha: func(ch authchallenge.TextCaptchaChallenge) (authchallenge.TextCaptchaResponse, error) {
				v, e := s.ask("image", "请输入图片中的验证码", ch.Image)
				return authchallenge.TextCaptchaResponse{Code: v}, e
			},
		},
	})
	defer vpn.Close()
	// Closing the client interrupts pending HTTP/transport setup on cancellation.
	stopClose := context.AfterFunc(s.ctx, vpn.Close)
	defer stopClose()
	s.emit(event{Kind: "phase", Phase: "connecting"})
	if err = vpn.Setup(); err != nil {
		return fmt.Errorf("authentication: %w", err)
	}
	if s.ctx.Err() != nil {
		return s.ctx.Err()
	}
	if vpn.CanUseTCPTunnel() {
		return errors.New("this server requires TCP-only mode")
	}
	ip, err := vpn.IP()
	if err != nil {
		return err
	}
	if ip == nil || ip.To4() == nil {
		return errors.New("TUN: IPv4 address unavailable")
	}
	dnsServers, err := vpn.DNSServers()
	if err != nil {
		return fmt.Errorf("DNS policy: %w", err)
	}
	serverDNS, err := ipv4DNSServers(dnsServers)
	if err != nil {
		return err
	}
	resources, err := vpn.IPResources()
	domains, domainErr := vpn.DomainResources()
	if err != nil && (domainErr != nil || len(domains) == 0) {
		return fmt.Errorf("resources: %w", err)
	}
	ipSet, err := vpn.IPSet()
	if (err != nil || ipSet == nil || len(ipSet.Prefixes()) == 0) && len(domains) == 0 {
		return errors.New("resources: no authorized IPv4 routes")
	}
	if ipSet == nil {
		builder := netaddr.IPSetBuilder{}
		ipSet, _ = builder.IPSet()
	}
	// The server supplied DNS endpoint is itself an authorized tunnel service.
	for _, address := range serverDNS {
		for _, network := range []string{"tcp", "udp"} {
			resources = append(resources, client.IPResource{IPMin: address, IPMax: address, PortMin: 53, PortMax: 53, Protocol: network})
		}
	}
	st, err := tun.NewStack(vpn, false, false, resources)
	if err != nil {
		return fmt.Errorf("TUN: %w", err)
	}
	defer st.Close()
	defer hook_func.ExecTerminalFunc(context.Background())
	routes := make([]string, 0, len(ipSet.Prefixes())+1)
	for _, prefix := range ipSet.Prefixes() {
		routes = append(routes, prefix.String())
	}
	for _, address := range serverDNS {
		dnsIP, _ := netaddr.FromStdIP(address)
		if !ipSet.Contains(dnsIP) {
			routes = append(routes, netaddr.IPPrefixFrom(dnsIP, 32).String())
		}
	}
	plan := &routePlan{session: s, stack: st, dnsAddress: localDNSAddress}
	defer plan.cleanup()
	if err = plan.install(s.ctx, routes); err != nil {
		return fmt.Errorf("route: %w", err)
	}
	dnsResources, _ := vpn.DNSResource()
	resolver := resolve.NewResolver(st, serverDNS[0].String(), serverDNS[0].String(), 300, domains, dnsResources, true)
	defer resolver.Close()
	forwarder := &dnsForwarder{stack: st, servers: serverDNS, ctx: s.ctx, resolver: resolver, plan: plan, static: dnsResources, capacity: make(chan struct{}, 64)}
	st.SetupResolve(forwarder)
	st.SetupIPPool(resolver.IPPool)
	if err = st.Prepare(); err != nil {
		return fmt.Errorf("tunnel: %w", err)
	}
	runErrors := make(chan error, 1)
	go func() { runErrors <- st.RunContext(s.ctx) }()
	// SO_REUSEADDR permits the concrete loopback address beside a wildcard
	// listener on Darwin; SO_REUSEPORT remains disabled so exact binds conflict.
	listenConfig := net.ListenConfig{Control: func(network, address string, raw syscall.RawConn) error {
		var socketErr error
		if err := raw.Control(func(fd uintptr) {
			socketErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		}); err != nil {
			return err
		}
		return socketErr
	}}
	udp, err := listenConfig.ListenPacket(s.ctx, "udp4", net.JoinHostPort(localDNSAddress, "53"))
	if err != nil {
		return fmt.Errorf("DNS listener: %w", err)
	}
	defer udp.Close()
	tcp, err := net.Listen("tcp4", net.JoinHostPort(localDNSAddress, "53"))
	if err != nil {
		return fmt.Errorf("DNS listener: %w", err)
	}
	defer tcp.Close()
	udpServer := &dns.Server{PacketConn: udp, Handler: forwarder}
	tcpServer := &dns.Server{Listener: tcp, Handler: forwarder}
	defer udpServer.Shutdown()
	defer tcpServer.Shutdown()
	serveErrors := make(chan error, 2)
	go func() { serveErrors <- udpServer.ActivateAndServe() }()
	go func() { serveErrors <- tcpServer.ActivateAndServe() }()
	defer s.cancel()
	// A DNS reply through the tunnel proves the transport can carry a request.
	check := new(dns.Msg)
	check.SetQuestion(".", dns.TypeNS)
	checkCtx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	readiness := make(chan error, 1)
	go func() { _, probeErr := forwarder.HandleDnsMsg(checkCtx, check); readiness <- probeErr }()
	select {
	case err = <-readiness:
		select {
		case runErr := <-runErrors:
			return fmt.Errorf("tunnel: %w", runErr)
		default:
		}
		if err != nil {
			return fmt.Errorf("DNS readiness: %w", err)
		}
	case err = <-runErrors:
		return fmt.Errorf("tunnel: %w", err)
	case err = <-serveErrors:
		return fmt.Errorf("DNS listener: %w", err)
	case <-s.ctx.Done():
		return s.ctx.Err()
	}
	cancel()
	s.emit(event{Kind: "ready", InterfaceName: st.InterfaceName(), DNSAddress: localDNSAddress, Routes: routes, CertificateSHA256: pinnedCertificate})
	select {
	case <-s.ctx.Done():
		return s.ctx.Err()
	case err = <-serveErrors:
		return fmt.Errorf("DNS listener: %w", err)
	case err = <-runErrors:
		return fmt.Errorf("tunnel: %w", err)
	}
}

// verifyServerBeforeCredentials probes TLS without sending an HTTP request or credentials.
func (s *session) verifyServerBeforeCredentials(c configuration, dialer *underlay.Dialer) (string, error) {
	ctx, cancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer cancel()
	raw, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(c.ServerHost, fmt.Sprint(c.ServerPort)))
	if err != nil {
		return "", err
	}
	conn := tls.Client(raw, &tls.Config{ServerName: c.ServerHost})
	defer conn.Close()
	stopIO := context.AfterFunc(ctx, func() { _ = raw.Close() })
	defer stopIO()
	err = conn.HandshakeContext(ctx)
	if err == nil {
		return "", nil
	}
	var verification *tls.CertificateVerificationError
	if !errors.As(err, &verification) || len(verification.UnverifiedCertificates) == 0 {
		return "", err
	}
	digest := sha256.Sum256(verification.UnverifiedCertificates[0].Raw)
	fingerprint := hex.EncodeToString(digest[:])
	if strings.EqualFold(c.TrustedCertificateSHA256, fingerprint) {
		return fingerprint, nil
	}
	answer, err := s.askEvent(event{Kind: "challenge", ChallengeKind: "certificate", CertificateSHA256: fingerprint,
		Message: "系统无法验证此服务端证书。仅在确认服务端身份后信任此证书。"})
	if err != nil {
		return "", err
	}
	if answer != "trust" {
		s.cancel()
		return "", context.Canceled
	}
	return fingerprint, nil
}

type dnsForwarder struct {
	stack    *tun.Stack
	servers  []net.IP
	ctx      context.Context
	resolver *resolve.Resolver
	plan     *routePlan
	static   map[string][]net.IP
	capacity chan struct{}
}

func (f *dnsForwarder) CheckDnsHijack(ip net.IP) bool {
	for _, address := range f.servers {
		if ip.Equal(address) {
			return false
		}
	}
	return true
}

// ipv4DNSServers preserves server policy order, removes duplicates and excludes unsupported IPv6 entries.
func ipv4DNSServers(values []string) ([]net.IP, error) {
	var addresses []net.IP
	seen := make(map[string]bool)
	for _, value := range values {
		address := net.ParseIP(strings.TrimSpace(value))
		if address == nil {
			return nil, errors.New("DNS policy: invalid server address")
		}
		address = address.To4()
		if address == nil || address.IsUnspecified() {
			continue
		}
		canonical := address.String()
		if !seen[canonical] {
			addresses = append(addresses, address)
			seen[canonical] = true
		}
	}
	if len(addresses) == 0 {
		return nil, errors.New("DNS policy: no usable IPv4 DNS servers")
	}
	return addresses, nil
}

// HandleDnsMsg forwards complete DNS messages through the tunnel, without a public fallback.
func (f *dnsForwarder) HandleDnsMsg(ctx context.Context, m *dns.Msg) (*dns.Msg, error) {
	queryCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	stopSession := context.AfterFunc(f.ctx, cancel)
	defer stopSession()
	select {
	case f.capacity <- struct{}{}:
		defer func() { <-f.capacity }()
	default:
		return nil, errors.New("DNS request limit reached")
	}
	exchange := func(attemptCtx context.Context, network string, remote net.IP) (*dns.Msg, error) {
		var conn net.Conn
		var err error
		if network == "udp" {
			conn, err = f.stack.DialUDP(attemptCtx, &net.UDPAddr{IP: remote, Port: 53})
		} else {
			conn, err = f.stack.DialTCP(attemptCtx, &net.TCPAddr{IP: remote, Port: 53})
		}
		if err != nil {
			return nil, err
		}
		defer conn.Close()
		stopIO := context.AfterFunc(attemptCtx, func() { _ = conn.Close() })
		defer stopIO()
		deadline, _ := attemptCtx.Deadline()
		_ = conn.SetDeadline(deadline)
		c := &dns.Conn{Conn: conn}
		if err = c.WriteMsg(m); err != nil {
			return nil, err
		}
		response, err := c.ReadMsg()
		if err != nil {
			return nil, err
		}
		if response == nil || response.Id != m.Id {
			return nil, errors.New("invalid DNS response")
		}
		return response, nil
	}
	var response *dns.Msg
	var err error
	if len(m.Question) == 1 && (m.Question[0].Qtype == dns.TypeA || m.Question[0].Qtype == dns.TypeAAAA) {
		q := m.Question[0]
		name := strings.ToLower(strings.TrimSuffix(q.Name, "."))
		if addresses, ok := f.static[name]; ok {
			response = new(dns.Msg)
			response.SetReply(m)
			for _, address := range addresses {
				header := dns.RR_Header{Name: q.Name, Rrtype: q.Qtype, Class: dns.ClassINET, Ttl: 300}
				if q.Qtype == dns.TypeA && address.To4() != nil {
					response.Answer = append(response.Answer, &dns.A{Hdr: header, A: address.To4()})
				}
				if q.Qtype == dns.TypeAAAA && address.To4() == nil && address.To16() != nil {
					response.Answer = append(response.Answer, &dns.AAAA{Hdr: header, AAAA: address.To16()})
				}
			}
		}
	}
	if response == nil {
		// Divide remaining time across remaining policy servers so the first cannot exhaust all retries.
		for index, remote := range f.servers {
			if queryCtx.Err() != nil {
				return nil, queryCtx.Err()
			}
			deadline, _ := queryCtx.Deadline()
			serverBudget := time.Until(deadline) / time.Duration(len(f.servers)-index)
			serverCtx, cancelServer := context.WithTimeout(queryCtx, serverBudget)
			udpBudget := serverBudget / 2
			if udpBudget > 3*time.Second {
				udpBudget = 3 * time.Second
			}
			udpCtx, cancelUDP := context.WithTimeout(serverCtx, udpBudget)
			response, err = exchange(udpCtx, "udp", remote)
			cancelUDP()
			if err != nil || response.Truncated {
				response, err = exchange(serverCtx, "tcp", remote)
			}
			cancelServer()
			// Any valid DNS reply, including NXDOMAIN/SERVFAIL, retains its original meaning.
			if err == nil {
				break
			}
		}
	}
	if err != nil {
		return nil, err
	}
	for _, question := range m.Question {
		resources, matched := f.resolver.MatchDomainResources(question.Name)
		if !matched {
			continue
		}
		var addresses []net.IP
		for _, answer := range response.Answer {
			if record, ok := answer.(*dns.A); ok {
				addresses = append(addresses, record.A)
			}
		}
		if err = f.plan.ensureIPs(queryCtx, addresses); err != nil {
			return nil, err
		}
		for _, address := range addresses {
			if err = f.resolver.IPPool.SetIPDomain(address, strings.ToLower(strings.TrimSuffix(question.Name, ".")), resources); err != nil {
				return nil, err
			}
		}
	}
	return response, nil
}

type routePlan struct {
	session      *session
	stack        *tun.Stack
	dnsAddress   string
	mu           sync.Mutex
	routes       []string
	added        []string
	dynamicCount int
}

// install persists the complete route plan through the supervisor before changing routes.
func (p *routePlan) install(ctx context.Context, routes []string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.installLocked(ctx, routes)
}

func (p *routePlan) installLocked(ctx context.Context, routes []string) error {
	planned := append(append([]string(nil), p.routes...), routes...)
	p.session.emit(event{Kind: "phase", Phase: "connecting", InterfaceName: p.stack.InterfaceName(), DNSAddress: p.dnsAddress, Routes: planned})
	select {
	case <-p.session.configured:
	case <-ctx.Done():
		return ctx.Err()
	case <-p.session.ctx.Done():
		return p.session.ctx.Err()
	}
	for _, route := range routes {
		if err := p.stack.AddRoute(route); err != nil {
			return err
		}
		p.added = append(p.added, route)
	}
	p.routes = planned
	return nil
}

// ensureIPs installs routes only for domain resources authorized by the server.
func (p *routePlan) ensureIPs(ctx context.Context, addresses []net.IP) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	var additions []string
	seen := make(map[string]bool)
	for _, address := range addresses {
		if p.stack.HasRouteForIP(address) {
			continue
		}
		ip, ok := netaddr.FromStdIP(address)
		if !ok || !ip.Is4() {
			continue
		}
		route := netaddr.IPPrefixFrom(ip, 32).String()
		if !seen[route] {
			additions = append(additions, route)
			seen[route] = true
		}
	}
	if len(additions) == 0 {
		return nil
	}
	if p.dynamicCount+len(additions) > 4096 {
		p.session.emit(event{Kind: "failed", Code: "resourcesUnavailable", Message: "本次连接的动态域名资源已达到上限，请重新连接"})
		p.session.cancel()
		return errors.New("domain route limit reached")
	}
	if err := p.installLocked(ctx, additions); err != nil {
		if p.session.ctx.Err() == nil {
			p.session.emit(event{Kind: "failed", Code: "routeFailed", Message: "内网域名路由配置失败"})
			p.session.cancel()
		}
		return err
	}
	p.dynamicCount += len(additions)
	return nil
}

func (p *routePlan) cleanup() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := len(p.added) - 1; i >= 0; i-- {
		_ = exec.Command("/sbin/route", "-n", "delete", "-net", p.added[i], "-interface", p.stack.InterfaceName()).Run()
	}
}

func (f *dnsForwarder) ServeDNS(w dns.ResponseWriter, m *dns.Msg) {
	response, err := f.HandleDnsMsg(f.ctx, m)
	if err != nil {
		response = new(dns.Msg)
		response.SetRcode(m, dns.RcodeServerFailure)
	}
	_ = w.WriteMsg(response)
}

// publicError never exposes an upstream response, account, endpoint or credential.
func publicError(err error) (string, string) {
	if errors.Is(err, easyconnect.ErrInvalidLoginResponse) {
		return "unsupportedServer", "该地址未返回受支持的 EasyConnect 登录信息，请检查 VPN 地址"
	}
	var unknown x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	if errors.As(err, &unknown) || errors.As(err, &hostname) || errors.As(err, &invalid) || strings.Contains(err.Error(), "certificate") {
		return "serverCertificate", "VPN 证书验证失败，请检查地址或系统证书信任设置"
	}
	var dnsError *net.DNSError
	var operationError *net.OpError
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "administrator"):
		return "authorizationRequired", "连接需要系统授权"
	case strings.HasPrefix(message, "dns listener"):
		return "dnsListenerFailed", "本地 DNS 监听未能启动，请检查端口占用"
	case strings.HasPrefix(message, "dns readiness"):
		return "dnsReadinessFailed", "已完成登录，但 VPN 域名解析服务没有响应"
	case strings.HasPrefix(message, "dns"):
		return "dnsUnavailable", "VPN 域名解析服务不可用"
	case strings.HasPrefix(message, "route"):
		return "routeFailed", "内网路由配置失败"
	case strings.HasPrefix(message, "resources"):
		return "resourcesUnavailable", "服务端未提供可用的内网资源"
	case strings.Contains(message, "tcp-only"):
		return "unsupportedMode", "服务端仅支持 TCP 隧道，当前版本需要 TUN 能力"
	case errors.As(err, &dnsError) || errors.As(err, &operationError) || errors.Is(err, context.DeadlineExceeded):
		return "connectionFailed", "无法访问 VPN 服务端，请检查地址和网络连接"
	case strings.HasPrefix(message, "authentication"):
		return "authenticationFailed", "登录失败，请检查地址、账号、密码及验证信息"
	default:
		return "connectionFailed", "VPN 连接失败，请检查网络和服务端配置"
	}
}
