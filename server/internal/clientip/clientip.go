// Package clientip decides which address a request came from. X-Forwarded-For is
// read only when the direct peer is a configured trusted proxy, and then only the
// rightmost hop that is not itself trusted counts; everything left of it is client-supplied.
package clientip

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"

	protocol "rcprotocol"
)

type Resolver struct {
	trusted []netip.Prefix
}

// Parse reads a comma-separated CIDR list; a bare address means that one host.
func Parse(spec string) (Resolver, error) {
	var r Resolver
	for _, item := range strings.Split(spec, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if !strings.Contains(item, "/") {
			addr, err := netip.ParseAddr(item)
			if err != nil {
				return Resolver{}, fmt.Errorf("trusted proxy %q is not an address or CIDR", item)
			}
			item = netip.PrefixFrom(addr, addr.BitLen()).String()
		}
		prefix, err := netip.ParsePrefix(item)
		if err != nil {
			return Resolver{}, fmt.Errorf("trusted proxy %q is not a CIDR", item)
		}
		r.trusted = append(r.trusted, prefix.Masked())
	}
	return r, nil
}

func (r Resolver) isTrusted(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, p := range r.trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

func peerAddr(remote string) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	addr, err := netip.ParseAddr(host)
	return addr.Unmap(), err == nil
}

// Of returns the client address of r as a string.
func (r Resolver) Of(req *http.Request) string {
	peer, ok := peerAddr(req.RemoteAddr)
	if !ok {
		return req.RemoteAddr
	}
	if !r.isTrusted(peer) {
		return peer.String()
	}
	hops := forwardedHops(req.Header.Values(protocol.HeaderForwardedFor))
	for i := len(hops) - 1; i >= 0; i-- {
		hop, err := netip.ParseAddr(hops[i])
		if err != nil {
			return peer.String()
		}
		hop = hop.Unmap()
		if !r.isTrusted(hop) {
			return hop.String()
		}
		peer = hop
	}
	return peer.String()
}

func forwardedHops(values []string) []string {
	var hops []string
	for _, v := range values {
		for _, hop := range strings.Split(v, ",") {
			if hop = strings.TrimSpace(hop); hop != "" {
				hops = append(hops, hop)
			}
		}
	}
	return hops
}
