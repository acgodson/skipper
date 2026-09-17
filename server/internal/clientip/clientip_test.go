package clientip

import (
	"net/http/httptest"
	"testing"

	protocol "rcprotocol"
)

func TestForwardedForIsHonouredOnlyFromTrustedProxies(t *testing.T) {
	trusted, err := Parse("10.0.0.0/8, 127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, remote, xff string
		resolver          Resolver
		want              string
	}{
		{"no proxies configured ignores the header", "203.0.113.9:5000", "198.51.100.1", Resolver{}, "203.0.113.9"},
		{"untrusted peer ignores the header", "203.0.113.9:5000", "198.51.100.1", trusted, "203.0.113.9"},
		{"trusted peer, one hop", "10.1.2.3:443", "198.51.100.1", trusted, "198.51.100.1"},
		{"spoofed left hops are ignored", "10.1.2.3:443", "1.2.3.4, 198.51.100.1", trusted, "198.51.100.1"},
		{"trusted hops are skipped from the right", "127.0.0.1:443", "198.51.100.1, 10.9.9.9", trusted, "198.51.100.1"},
		{"all hops trusted gives the leftmost", "10.1.2.3:443", "10.2.2.2, 10.3.3.3", trusted, "10.2.2.2"},
		{"garbage hop stops at the last good peer", "10.1.2.3:443", "198.51.100.1, not-an-ip", trusted, "10.1.2.3"},
		{"trusted peer without the header", "10.1.2.3:443", "", trusted, "10.1.2.3"},
		{"v4-mapped peer", "[::ffff:10.1.2.3]:443", "198.51.100.1", trusted, "198.51.100.1"},
	}
	for _, c := range cases {
		req := httptest.NewRequest("GET", "/", nil)
		req.RemoteAddr = c.remote
		if c.xff != "" {
			req.Header.Set(protocol.HeaderForwardedFor, c.xff)
		}
		if got := c.resolver.Of(req); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestParseRejectsGarbage(t *testing.T) {
	for _, bad := range []string{"10.0.0.0/33", "example.com", "10.0.0/8"} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q) accepted", bad)
		}
	}
	if r, err := Parse(""); err != nil || len(r.trusted) != 0 {
		t.Fatalf("empty spec: %+v %v", r, err)
	}
}
