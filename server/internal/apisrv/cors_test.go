package apisrv

import (
	"net/http"
	"strconv"
	"testing"

	"rc-signal/internal/idp"
	protocol "rcprotocol"
)

func (h *harness) fromBrowser(method, origin string, idemKey string, body any) reply {
	h.t.Helper()
	header := http.Header{}
	if origin != "" {
		header.Set(headerOrigin, origin)
	}
	credential := ""
	if body != nil {
		credential = "dev:browser@example.com"
	}
	return h.callAt(h.url, method, protocol.PathAuthLink, credential, idemKey, body, header)
}

func linkBody(d device) protocol.LinkRequest {
	return protocol.LinkRequest{Nonce: appNonce, Pubkey: d.pubkey, Platform: protocol.PlatformMacOS}
}

func TestLinkPreflightAnswersTheWebsite(t *testing.T) {
	h := newHarness(t)
	r := h.fromBrowser("OPTIONS", testWebOrigin, "", nil)
	if r.status != http.StatusNoContent {
		t.Fatalf("preflight: %d %s", r.status, r.body)
	}
	if got := r.header.Get(headerAllowOrigin); got != testWebOrigin {
		t.Fatalf("preflight %s = %q, want %q", headerAllowOrigin, got, testWebOrigin)
	}
	if got := r.header.Get(headerAllowMethods); got != http.MethodPost {
		t.Fatalf("preflight %s = %q, want POST only", headerAllowMethods, got)
	}
	if got := r.header.Get(headerAllowHeaders); got != corsAllowedHeaders {
		t.Fatalf("preflight %s = %q, want %q", headerAllowHeaders, got, corsAllowedHeaders)
	}
	if got := r.header.Get(headerCORSMaxAge); got != strconv.Itoa(corsPreflightMaxAge) {
		t.Fatalf("preflight %s = %q", headerCORSMaxAge, got)
	}
	if got := r.header.Get(headerVary); got != headerOrigin {
		t.Fatalf("preflight %s = %q, want Origin", headerVary, got)
	}
}

// The half that fails silently: a 409 the browser may not read is an unexplained
// failure on screen, and the "that Mac belongs to another account" message — the
// only one that tells an owner what to do — never appears.
func TestLinkErrorsCarryTheCORSHeader(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	h.link("owner@example.com", mac, "SERIAL-CORS")

	cases := []struct {
		name   string
		status int
		code   string
		reason string
		body   any
	}{
		{"linked elsewhere", http.StatusConflict, protocol.APIErrConflict, protocol.ReasonLinkedElsewhere,
			linkBody(mac)},
		{"bad pubkey", http.StatusBadRequest, protocol.APIErrBadRequest, "",
			protocol.LinkRequest{Nonce: appNonce, Pubkey: "not-a-key", Platform: protocol.PlatformMacOS}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := h.fromBrowser("POST", testWebOrigin, idem(), c.body)
			if r.status != c.status {
				t.Fatalf("status %d %s, want %d", r.status, r.body, c.status)
			}
			e := r.apiError(t)
			if e.Code != c.code || (c.reason != "" && e.Reason != c.reason) {
				t.Fatalf("envelope %+v", e)
			}
			if got := r.header.Get(headerAllowOrigin); got != testWebOrigin {
				t.Fatalf("%d answer carries %s = %q; the browser cannot read this body",
					r.status, headerAllowOrigin, got)
			}
			if got := r.header.Get(headerVary); got != headerOrigin {
				t.Fatalf("%d answer carries %s = %q", r.status, headerVary, got)
			}
		})
	}

	unauthenticated := h.callAt(h.url, "POST", protocol.PathAuthLink, "", idem(), linkBody(newDevice(t)),
		http.Header{headerOrigin: {testWebOrigin}})
	if unauthenticated.status != http.StatusUnauthorized {
		t.Fatalf("no credential: %d %s", unauthenticated.status, unauthenticated.body)
	}
	if got := unauthenticated.header.Get(headerAllowOrigin); got != testWebOrigin {
		t.Fatalf("401 answer carries %s = %q", headerAllowOrigin, got)
	}
}

func TestLinkSuccessCarriesTheCORSHeaderAndNoCredentialWidening(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	h.register(mac)
	r := h.fromBrowser("POST", testWebOrigin, idem(), linkBody(mac))
	if r.status != http.StatusCreated {
		t.Fatalf("link: %d %s", r.status, r.body)
	}
	if got := r.header.Get(headerAllowOrigin); got != testWebOrigin {
		t.Fatalf("201 answer carries %s = %q", headerAllowOrigin, got)
	}
	if got := r.header.Get("Access-Control-Allow-Credentials"); got != "" {
		t.Fatalf("the route allows credentials: %q", got)
	}
}

func TestLinkRefusesAnyOtherOrigin(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	h.register(mac)
	for _, origin := range []string{
		"https://skipperdesk.test.evil.example",
		"https://www.skipperdesk.test",
		"http://skipperdesk.test",
		"null",
	} {
		for _, method := range []string{"OPTIONS", "POST"} {
			var body any
			key := ""
			if method == "POST" {
				body = linkBody(mac)
				key = idem()
			}
			r := h.fromBrowser(method, origin, key, body)
			if got := r.header.Get(headerAllowOrigin); got != "" {
				t.Fatalf("%s from %s was allowed: %s = %q", method, origin, headerAllowOrigin, got)
			}
			if got := r.header.Get(headerVary); got != headerOrigin {
				t.Fatalf("%s from %s: %s = %q", method, origin, headerVary, got)
			}
		}
	}
}

// Nothing else is called from a browser, so nothing else answers one.
func TestNoOtherRouteCarriesCORS(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	grant := h.link("solo@example.com", mac, "SERIAL-SOLO")
	header := http.Header{headerOrigin: {testWebOrigin}}
	for _, route := range []struct {
		method     string
		path       string
		credential string
	}{
		{"GET", protocol.PathHealth, ""},
		{"GET", protocol.PathEntitlement, grant.DeviceToken},
		{"GET", protocol.PathDevices, grant.DeviceToken},
		{"POST", protocol.PathAuthDeviceChallenge, ""},
		{"OPTIONS", protocol.PathEntitlement, ""},
	} {
		r := h.callAt(h.url, route.method, route.path, route.credential, "", nil, header)
		if got := r.header.Get(headerAllowOrigin); got != "" {
			t.Fatalf("%s %s carries %s = %q", route.method, route.path, headerAllowOrigin, got)
		}
	}
}

type namedIdP struct{ idp.Provider }

func (n namedIdP) Name() string { return "cognito" }

// The API host no longer serves a sign-in page; skipperdesk.app does.
func TestLinkPageIsOnlyTheDevStandIn(t *testing.T) {
	h := newHarness(t)
	if r := h.callAt(h.url, "GET", "/link", "", "", nil, nil); r.status != http.StatusBadRequest {
		t.Fatalf("the dev stand-in is gone: %d %s", r.status, r.body)
	}
	deployed := h.withIdP(namedIdP{idp.Dev{}})
	for _, method := range []string{"GET", "POST"} {
		r := h.callAt(deployed, method, "/link", "", "", nil, nil)
		if r.status != http.StatusNotFound || r.apiError(t).Code != protocol.APIErrNotFound {
			t.Fatalf("%s /link under a deployed IdP: %d %s", method, r.status, r.body)
		}
	}
}

func TestWebOriginOf(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"", ""},
		{"https://skipperdesk.app", "https://skipperdesk.app"},
		{"https://skipperdesk.app/", "https://skipperdesk.app"},
		{" https://skipperdesk.app/link ", "https://skipperdesk.app"},
		{"http://127.0.0.1:18080", "http://127.0.0.1:18080"},
	} {
		got, err := webOriginOf(c.in)
		if err != nil || got != c.want {
			t.Fatalf("webOriginOf(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	for _, bad := range []string{"skipperdesk.app", "https://", "wss://skipperdesk.app", "/link"} {
		if _, err := webOriginOf(bad); err == nil {
			t.Fatalf("webOriginOf(%q) was accepted", bad)
		}
	}
}
