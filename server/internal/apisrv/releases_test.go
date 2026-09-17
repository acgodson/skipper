package apisrv

import (
	"net/http"
	"strings"
	"testing"
	"time"

	protocol "rcprotocol"
)

const publisher = "dev:release@example.com"

func devRelease(arch, channel, build string) protocol.DevReleaseRequest {
	return protocol.DevReleaseRequest{
		Platform: protocol.PlatformMacOS, Arch: arch, Channel: channel,
		Version: "1.0." + build, Build: build, MinimumOS: "13.0",
		URL:    "https://downloads.example.com/SkipperDesk-" + build + ".dmg",
		SHA256: strings.Repeat("ab", 32), Size: 1234,
	}
}

func (h *harness) publish(req protocol.DevReleaseRequest) {
	h.t.Helper()
	if r := h.call("POST", protocol.PathDevReleases, publisher, "", req); r.status != http.StatusCreated {
		h.t.Fatalf("publish %+v: %d %s", req, r.status, r.body)
	}
	h.clock.advance(time.Second)
}

func (h *harness) latest(query string) (int, protocol.AppRelease, reply) {
	h.t.Helper()
	r := h.call("GET", protocol.PathAppReleasesLatest+"?"+query, "", "", nil)
	var out protocol.AppRelease
	if r.status == http.StatusOK {
		r.decode(h.t, &out)
	}
	return r.status, out, r
}

func TestLatestReleaseFiltersByArchAndChannel(t *testing.T) {
	h := newHarness(t)
	if status, _, r := h.latest("platform=macos&arch=arm64"); status != http.StatusNotFound {
		t.Fatalf("empty table: %d %s, want 404", status, r.body)
	}

	h.publish(devRelease(protocol.ArchARM64, protocol.ChannelStable, "3"))
	h.publish(devRelease(protocol.ArchARM64, protocol.ChannelBeta, "5"))
	h.publish(devRelease(protocol.ArchX86_64, protocol.ChannelStable, "4"))
	critical := devRelease(protocol.ArchARM64, protocol.ChannelStable, "4")
	critical.Critical = true
	h.publish(critical)

	status, got, r := h.latest("platform=macos&arch=arm64&channel=stable")
	if status != http.StatusOK || got.Build != "4" || !got.Critical {
		t.Fatalf("stable arm64: %d %+v", status, got)
	}
	if got.SHA256 != strings.Repeat("ab", 32) || got.Size != 1234 || got.MinimumOS != "13.0" || got.PublishedAt == 0 {
		t.Fatalf("release fields not round-tripped: %+v", got)
	}
	if cc := r.header.Get("Cache-Control"); !strings.Contains(cc, "public") {
		t.Fatalf("Cache-Control %q, want a public cacheable answer", cc)
	}

	if _, got, _ := h.latest("platform=macos&arch=arm64"); got.Build != "4" {
		t.Fatalf("channel should default to stable, got build %s", got.Build)
	}
	if _, got, _ := h.latest("platform=macos&arch=arm64&channel=beta"); got.Build != "5" {
		t.Fatalf("beta arm64: build %s, want 5", got.Build)
	}
	if _, got, _ := h.latest("platform=macos&arch=x86_64&channel=stable"); got.Build != "4" || got.Critical {
		t.Fatalf("stable x86_64: %+v", got)
	}
	if status, _, _ := h.latest("platform=macos&arch=x86_64&channel=beta"); status != http.StatusNotFound {
		t.Fatalf("x86_64 beta: %d, want 404", status)
	}
}

func TestLatestReleaseIsTheMostRecentlyPublished(t *testing.T) {
	h := newHarness(t)
	h.publish(devRelease(protocol.ArchARM64, protocol.ChannelStable, "7"))
	h.publish(devRelease(protocol.ArchARM64, protocol.ChannelStable, "6"))
	if _, got, _ := h.latest("platform=macos&arch=arm64"); got.Build != "6" {
		t.Fatalf("a pulled release is replaced by republishing the previous one; got build %s", got.Build)
	}
	h.publish(devRelease(protocol.ArchARM64, protocol.ChannelStable, "7"))
	if _, got, _ := h.latest("platform=macos&arch=arm64"); got.Build != "7" {
		t.Fatalf("republishing the same build must update it in place; got build %s", got.Build)
	}
}

func TestLatestReleaseRejectsBadQueries(t *testing.T) {
	h := newHarness(t)
	for _, q := range []string{
		"arch=arm64",
		"platform=windows&arch=arm64",
		"platform=macos",
		"platform=macos&arch=ppc",
		"platform=macos&arch=arm64&channel=nightly",
		"platform=macos&arch=arm64&extra=1",
	} {
		if status, _, r := h.latest(q); status != http.StatusBadRequest {
			t.Fatalf("%s: %d %s, want 400", q, status, r.body)
		}
	}
}

func TestLatestReleaseIsRateLimitedPerIP(t *testing.T) {
	h := newHarness(t)
	for i := 0; i < int(limitReleaseLatest.limit); i++ {
		if status, _, _ := h.latest("platform=macos&arch=arm64"); status == http.StatusTooManyRequests {
			t.Fatalf("limited after %d calls", i)
		}
	}
	status, _, r := h.latest("platform=macos&arch=arm64")
	if status != http.StatusTooManyRequests || r.apiError(t).RetryAfterSec <= 0 {
		t.Fatalf("call over the limit: %d %s", status, r.body)
	}
}

func TestDevPublishReleaseValidates(t *testing.T) {
	h := newHarness(t)
	mutations := map[string]func(*protocol.DevReleaseRequest){
		"plain http elsewhere": func(r *protocol.DevReleaseRequest) { r.URL = "http://downloads.example.com/a.dmg" },
		"not a url":            func(r *protocol.DevReleaseRequest) { r.URL = "ftp://x/a.dmg" },
		"short sha":            func(r *protocol.DevReleaseRequest) { r.SHA256 = "abcd" },
		"zero size":            func(r *protocol.DevReleaseRequest) { r.Size = 0 },
		"textual build":        func(r *protocol.DevReleaseRequest) { r.Build = "3b" },
		"empty version":        func(r *protocol.DevReleaseRequest) { r.Version = "" },
		"unknown arch":         func(r *protocol.DevReleaseRequest) { r.Arch = "ppc" },
	}
	for name, mutate := range mutations {
		req := devRelease(protocol.ArchARM64, protocol.ChannelStable, "3")
		mutate(&req)
		if r := h.call("POST", protocol.PathDevReleases, publisher, "", req); r.status != http.StatusBadRequest {
			t.Fatalf("%s: %d %s, want 400", name, r.status, r.body)
		}
	}
	local := devRelease(protocol.ArchARM64, protocol.ChannelStable, "3")
	local.URL = "http://127.0.0.1:18080/SkipperDesk.dmg"
	h.publish(local)

	if r := h.call("POST", protocol.PathDevReleases, "", "", local); r.status != http.StatusUnauthorized {
		t.Fatalf("anonymous publish: %d, want 401", r.status)
	}
}
