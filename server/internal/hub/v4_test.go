package hub

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"rcprotocol"
)

func (hn *harness) controller(label string) *peer {
	hn.t.Helper()
	c := hn.newPeer()
	c.register(label)
	c.hello(protocol.RoleController)
	return c
}

func (p *peer) connect(hostID string) (protocol.ConnectOK, bool) {
	p.t.Helper()
	p.reset()
	p.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID})
	if !p.has(protocol.TypeConnectOK) {
		return protocol.ConnectOK{}, false
	}
	return unmarshal[protocol.ConnectOK](p.t, p.last(protocol.TypeConnectOK)), true
}

func TestASessionIsMeteredOnlyOnceTheHostSendsItsFirstSDP(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	for i := 0; i < 3; i++ {
		ok, opened := ctrl.connect(host.deviceID)
		if !opened {
			t.Fatalf("connect %d: %s", i, ctrl.typesLocked())
		}
		ctrl.send(protocol.TypePake, protocol.Pake{SessionID: ok.SessionID, Step: 1, Payload: "cA=="})
		host.send(protocol.TypePake, protocol.Pake{SessionID: ok.SessionID, Step: 2, Payload: "cA=="})
		ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "offer", SDP: "v=0\r\n"})
		host.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeAuthFailed})
	}
	time.Sleep(50 * time.Millisecond)
	if starts, stops := hn.ent.reportCounts(); starts != 0 || stops != 0 {
		t.Fatalf("sessions the host never answered were reported: %d starts, %d stops", starts, stops)
	}
	if live := hn.hub.LiveMeteredSessions(); len(live.SessionIDs) != 0 {
		t.Fatalf("unmetered sessions listed as live: %v", live.SessionIDs)
	}

	ok, _ := ctrl.connect(host.deviceID)
	hn.clock.Advance(3 * time.Second)
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "offer", SDP: "v=0\r\n"})
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "offer", SDP: "v=0\r\n", Restart: true})
	starts, _ := hn.ent.awaitReports(t, 1, 0)
	if len(starts) != 1 || starts[0].SessionID != ok.SessionID || starts[0].StartedAt != hn.clock.Now().UnixMilli() {
		t.Fatalf("start reports = %+v, want one at the host's first sdp", starts)
	}
	if live := hn.hub.LiveMeteredSessions(); len(live.SessionIDs) != 1 || live.SessionIDs[0] != ok.SessionID {
		t.Fatalf("live metered sessions = %v", live.SessionIDs)
	}
	ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
	_, stops := hn.ent.awaitReports(t, 1, 1)
	if len(stops) != 1 || stops[0].SessionID != ok.SessionID {
		t.Fatalf("stop reports = %+v", stops)
	}
	if live := hn.hub.LiveMeteredSessions(); len(live.SessionIDs) != 0 {
		t.Fatalf("a closed session is still listed: %v", live.SessionIDs)
	}
}

func TestTightConnectByeLoopsReportEveryStopAfterItsStart(t *testing.T) {
	hn := newHarness(t)
	host := hn.newPeer()
	host.register("host")
	host.hello(protocol.RoleHost)
	const loops = 120
	var ids []string
	for i := 0; i < loops; i++ {
		if i%protocol.ConnectPerControllerPerMin == 0 {
			hn.clock.Advance(time.Minute)
		}
		ctrl := hn.connectingController(i)
		ok, opened := ctrl.connect(host.deviceID)
		if !opened {
			t.Fatalf("loop %d: %s %+v", i, ctrl.typesLocked(), ctrl.lastErr())
		}
		host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "answer", SDP: "v=0\r\n"})
		ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
		ids = append(ids, ok.SessionID)
	}
	hn.ent.awaitReports(t, loops, loops)
	hn.ent.mu.Lock()
	defer hn.ent.mu.Unlock()
	position := map[string]int{}
	for i, entry := range hn.ent.order {
		position[entry] = i
	}
	for _, id := range ids {
		start, okStart := position["start "+id]
		stop, okStop := position["stop "+id]
		if !okStart || !okStop || stop < start {
			t.Fatalf("session %s: start@%d(%v) stop@%d(%v)", id, start, okStart, stop, okStop)
		}
	}
}

func (hn *harness) connectingController(i int) *peer {
	if len(hn.pool) == 0 {
		for j := 0; j < 8; j++ {
			c := hn.newPeerAt(fmt.Sprintf("198.51.100.%d", j+1))
			c.register(fmt.Sprintf("ctrl-%d", j))
			c.hello(protocol.RoleController)
			hn.pool = append(hn.pool, c)
		}
	}
	return hn.pool[i%len(hn.pool)]
}

func TestADeniedStartReportEndsTheSession(t *testing.T) {
	hn := newHarness(t)
	hn.ent.denyStart = true
	host, ctrl := hn.pair(t)
	ok, _ := ctrl.connect(host.deviceID)
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "offer", SDP: "v=0\r\n"})
	deadline := time.Now().Add(2 * time.Second)
	for hn.hub.SessionState(ok.SessionID) != "" {
		if time.Now().After(deadline) {
			t.Fatal("a session rc-api refused to meter kept running")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if b := unmarshal[protocol.Bye](t, ctrl.last(protocol.TypeBye)); b.Reason != protocol.ByeError {
		t.Fatalf("bye = %+v", b)
	}
	if _, stops := hn.ent.reportCounts(); stops != 0 {
		t.Fatal("a stop was reported for a start rc-api never recorded")
	}
}

func TestConnectReqIsRateLimitedPerControllerAndPerHost(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	for i := 0; i < protocol.ConnectPerControllerPerMin; i++ {
		ok, opened := ctrl.connect(host.deviceID)
		if !opened {
			t.Fatalf("attempt %d refused: %+v", i, ctrl.lastErr())
		}
		ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
	}
	if _, opened := ctrl.connect(host.deviceID); opened {
		t.Fatal("a 7th connect_req in a minute opened a session")
	}
	e := ctrl.lastErr()
	if e.Code != protocol.ErrRateLimited || e.RetryAfterSec < 1 || e.RetryAfterSec > 60 {
		t.Fatalf("7th connect_req = %+v, want rate_limited with retryAfterSec", e)
	}
	host.reset()
	if _, opened := ctrl.connect("123456789"); opened || ctrl.lastErr().Code != protocol.ErrRateLimited {
		t.Fatal("the per-controller budget does not cover other targets")
	}
	if host.has(protocol.TypeSessionStart) {
		t.Fatal("a rate-limited attempt reached the host")
	}
	hn.clock.Advance(time.Duration(e.RetryAfterSec) * time.Second)
	if _, opened := ctrl.connect(host.deviceID); !opened {
		t.Fatalf("still refused after retryAfterSec: %+v", ctrl.lastErr())
	}

	target := hn.newPeer()
	target.register("busy host")
	target.hello(protocol.RoleHost)
	opened := 0
	var last protocol.Error
	for i := 0; i < 40; i++ {
		c := hn.connectingController(i)
		if ok, done := c.connect(target.deviceID); done {
			opened++
			c.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
		} else {
			last = c.lastErr()
		}
	}
	if opened != protocol.ConnectPerHostPerMin || last.Code != protocol.ErrRateLimited || last.RetryAfterSec < 1 {
		t.Fatalf("one host, many controllers: %d sessions opened, last error %+v; want %d then rate_limited",
			opened, last, protocol.ConnectPerHostPerMin)
	}
}

func TestRolesAreEnforced(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	host.reset()
	host.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: ctrl.deviceID})
	if host.has(protocol.TypeConnectOK) || host.lastErr().Code != protocol.ErrForbidden {
		t.Fatalf("a host connection sent connect_req: %s", host.typesLocked())
	}

	asController := hn.controller("a host that said controller")
	other := hn.controller("other")
	asController.reset()
	if _, opened := other.connect(asController.deviceID); opened {
		t.Fatal("a session was opened to a device connected as a controller")
	}
	if got := other.lastErr().Code; got != protocol.ErrOffline {
		t.Fatalf("connect to a controller-role device = %q, want offline", got)
	}
	if asController.has(protocol.TypeSessionStart) {
		t.Fatal("a controller-role connection received session_start")
	}
}

func TestByeReasonsOutsideTheDefinedSetAreRefused(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)
	for _, reason := range []string{strings.Repeat("A", 70*1024), "", "user", "declined\n"} {
		host.reset()
		ctrl.reset()
		ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: sid, Reason: reason})
		if got := ctrl.lastErr().Code; got != protocol.ErrBadRequest {
			t.Fatalf("bye reason %.12q: error = %q, want bad_request", reason, got)
		}
		if host.has(protocol.TypeBye) || hn.hub.SessionState(sid) != protocol.SessionOpen {
			t.Fatalf("bye reason %.12q was acted on", reason)
		}
	}
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid + "|x", SessionToken: "t"})
	if got := ctrl.lastErr().Code; got != protocol.ErrBadRequest {
		t.Fatalf("a malformed resume sessionId = %q, want bad_request", got)
	}
	ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: sid, Reason: protocol.ByeDeclined})
	if b := unmarshal[protocol.Bye](t, host.last(protocol.TypeBye)); b.Reason != protocol.ByeDeclined {
		t.Fatalf("a defined reason was not relayed: %+v", b)
	}
}
