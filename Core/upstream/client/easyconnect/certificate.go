package easyconnect

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"net"
	"strings"

	utls "github.com/refraction-networking/utls"
)

// verifyPinnedLeaf accepts only the exact certificate explicitly approved by the caller.
func (c *Client) verifyPinnedLeaf(certificates []*x509.Certificate) error {
	if len(certificates) == 0 {
		return errors.New("server certificate is missing")
	}
	digest := sha256.Sum256(certificates[0].Raw)
	if !strings.EqualFold(hex.EncodeToString(digest[:]), c.pinnedCertificateSHA256) {
		return errors.New("server certificate does not match trusted SHA-256 fingerprint")
	}
	return nil
}

func (c *Client) applyHTTPTrust(config *tls.Config) {
	if !c.verifyServerCertificate && c.pinnedCertificateSHA256 == "" {
		return
	}
	config.ServerName, _, _ = net.SplitHostPort(c.server)
	config.RootCAs = nil
	if c.pinnedCertificateSHA256 != "" {
		// The custom verifier replaces PKI validation, but never accepts another leaf.
		config.InsecureSkipVerify = true
		config.VerifyConnection = func(state tls.ConnectionState) error { return c.verifyPinnedLeaf(state.PeerCertificates) }
	} else {
		config.InsecureSkipVerify = false
	}
}

func (c *Client) applyTunnelTrust(config *utls.Config) {
	if !c.verifyServerCertificate && c.pinnedCertificateSHA256 == "" {
		return
	}
	config.ServerName, _, _ = net.SplitHostPort(c.server)
	config.RootCAs = nil
	if c.pinnedCertificateSHA256 != "" {
		config.InsecureSkipVerify = true
		config.VerifyConnection = func(state utls.ConnectionState) error { return c.verifyPinnedLeaf(state.PeerCertificates) }
	} else {
		config.InsecureSkipVerify = false
	}
}
