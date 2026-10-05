package hub

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"rc-signal/internal/auth"
	"rcprotocol"
)

func (p *peer) sendRaw(frame string) {
	p.t.Helper()
	p.h.Handle(p.c, []byte(frame))
}

func relayFrame(msgType, payload string) string {
	return fmt.Sprintf(`{"v":%d,"type":%q,"id":"r1","payload":%s}`, protocol.Version, msgType, payload)
}

func (p *peer) lastPayload(typ string) string {
	p.t.Helper()
	return string(p.last(typ).Payload)
}

func (p *peer) indexOf(typ string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	for i, m := range p.msgs {
		if m.Type == typ {
			return i
		}
	}
	return -1
}

func turnOf(t *testing.T, servers []protocol.ICEServer) protocol.ICEServer {
	t.Helper()
	for _, s := range servers {
		if s.Credential != "" {
			return s
		}
	}
	t.Fatalf("no TURN entry in %+v", servers)
	return protocol.ICEServer{}
}

func hasCredentials(servers []protocol.ICEServer) bool {
	for _, s := range servers {
		if s.Username != "" || s.Credential != "" {
			return true
		}
	}
	return false
}

func TestTurnArrivesOnlyOnceTheSessionIsMeteredAndLastsTenMinutes(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	host.reset()
	ok, _ := ctrl.connect(host.deviceID)
	start := unmarshal[protocol.SessionStart](t, host.last(protocol.TypeSessionStart))
	for name, servers := range map[string][]protocol.ICEServer{"connect_ok": ok.ICEServers, "session_start": start.ICEServers} {
		if len(servers) != 1 || servers[0].URLs[0] != "stun:stun.example:3478" || hasCredentials(servers) {
			t.Fatalf("%s iceServers = %+v, want STUN only", name, servers)
		}
	}

	ctrl.reset()
	ctrl.send(protocol.TypeRenew, protocol.Renew{SessionID: ok.SessionID, SessionToken: ok.SessionToken})
	renewed := unmarshal[protocol.RenewOK](t, ctrl.last(protocol.TypeRenewOK))
	if len(renewed.ICEServers) != 0 {
		t.Fatalf("an unmetered session's renew_ok carried iceServers: %+v", renewed.ICEServers)
	}
	ctrl.send(protocol.TypePake, protocol.Pake{SessionID: ok.SessionID, Step: 1, Payload: "cA=="})
	host.send(protocol.TypePake, protocol.Pake{SessionID: ok.SessionID, Step: 2, Payload: "cA=="})
	if host.has(protocol.TypeICEServers) || ctrl.has(protocol.TypeICEServers) {
		t.Fatal("TURN was handed out before the host's first sdp")
	}

	hn.clock.Advance(time.Minute)
	ctrl.reset()
	host.reset()
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "answer", SDP: "v=0\r\n"})
	wantUser, wantCred, wantExp := auth.TurnCreds("turnsecret", ok.SessionID, hn.clock.Now(), TurnCredTTL)
	for name, p := range map[string]*peer{"host": host, "controller": ctrl} {
		push := unmarshal[protocol.ICEServers](t, p.last(protocol.TypeICEServers))
		turn := turnOf(t, push.ICEServers)
		if push.SessionID != ok.SessionID || turn.Username != wantUser || turn.Credential != wantCred ||
			turn.ExpiresAt != wantExp.UnixMilli() || !strings.HasSuffix(turn.Username, ":"+ok.SessionID) {
			t.Fatalf("%s ice_servers = %+v", name, push)
		}
		if p.count(protocol.TypeICEServers) != 1 {
			t.Fatalf("%s got %d ice_servers pushes", name, p.count(protocol.TypeICEServers))
		}
	}
	if TurnCredTTL != 10*time.Minute {
		t.Fatalf("TURN credentials live %v, want 10 minutes", TurnCredTTL)
	}
	if ctrl.indexOf(protocol.TypeICEServers) > ctrl.indexOf(protocol.TypeSDP) {
		t.Fatal("the controller got the host's answer before its TURN credentials")
	}
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "offer", SDP: "v=0\r\n", Restart: true})
	if host.count(protocol.TypeICEServers) != 1 {
		t.Fatal("a later host sdp pushed TURN again")
	}

	hn.clock.Advance(5 * time.Minute)
	ctrl.reset()
	ctrl.send(protocol.TypeRenew, protocol.Renew{SessionID: ok.SessionID, SessionToken: renewed.SessionToken})
	fresh := unmarshal[protocol.RenewOK](t, ctrl.last(protocol.TypeRenewOK))
	freshUser, _, freshExp := auth.TurnCreds("turnsecret", ok.SessionID, hn.clock.Now(), TurnCredTTL)
	if turn := turnOf(t, fresh.ICEServers); turn.Username != freshUser || turn.ExpiresAt != freshExp.UnixMilli() {
		t.Fatalf("a metered session's renew_ok = %+v, want fresh TURN", fresh.ICEServers)
	}

	ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
	ctrl.reset()
	ctrl.send(protocol.TypeRenew, protocol.Renew{SessionID: ok.SessionID, SessionToken: fresh.SessionToken})
	if ctrl.has(protocol.TypeRenewOK) || ctrl.lastErr().Code != protocol.ErrNoSession {
		t.Fatal("an ended session still renewed its TURN credentials")
	}
}

func TestRelayedPayloadsAreDecodedStrictlyAndReencoded(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)
	for name, payload := range map[string]string{
		"sdp inside ice":          `{"sessionId":"` + sid + `","candidate":"","sdp":"v=0 offer","sdpType":"offer"}`,
		"case-variant session id": `{"sessionId":"ffffffffffffffffffffffffffffffff","SESSIONID":"` + sid + `","candidate":""}`,
		"duplicate session id":    `{"sessionId":"ffffffffffffffffffffffffffffffff","sessionId":"` + sid + `","candidate":""}`,
		"unknown key":             `{"sessionId":"` + sid + `","candidate":"","note":"x"}`,
		"not a candidate":         `{"sessionId":"` + sid + `","candidate":"v=0 o=- 0 0 IN IP4 127.0.0.1"}`,
		"null mid":                `{"sessionId":"` + sid + `","candidate":"","sdpMid":null}`,
	} {
		host.reset()
		ctrl.reset()
		ctrl.sendRaw(relayFrame(protocol.TypeICE, payload))
		if host.has(protocol.TypeICE) {
			t.Fatalf("%s: relayed", name)
		}
		if e := ctrl.lastErr(); e.Code != protocol.ErrBadRequest || len(e.Message) > MaxRelayErrorBytes {
			t.Fatalf("%s: error = %+v", name, e)
		}
	}
	host.sendRaw(relayFrame(protocol.TypeICE, `{"sessionId":"`+sid+`","candidate":"","sdp":"v=0","sdpType":"answer"}`))
	if starts, _ := hn.ent.reportCounts(); starts != 0 || ctrl.has(protocol.TypeICEServers) {
		t.Fatal("an sdp smuggled in ice started anything")
	}

	host.reset()
	ctrl.sendRaw(relayFrame(protocol.TypeICE,
		` { "sdpMLineIndex" : 0 , "candidate" : "candidate:1 1 udp 1 192.0.2.1 9 typ host" , "sessionId" : "`+sid+`" } `))
	want := `{"sessionId":"` + sid + `","candidate":"candidate:1 1 udp 1 192.0.2.1 9 typ host","sdpMLineIndex":0}`
	if got := host.lastPayload(protocol.TypeICE); got != want {
		t.Fatalf("relayed payload = %s, want the server's re-encoding %s", got, want)
	}
	if e := host.last(protocol.TypeICE); e.ID != "" || e.Re != "" {
		t.Fatalf("the relayed envelope carried the sender's correlation: %+v", e)
	}

	ctrl.reset()
	ctrl.sendRaw(relayFrame(protocol.TypeSDP, `{"sessionId":"`+sid+`","sdpType":"offer","sdp":"v=0","SDP":"v=0 other"}`))
	ctrl.sendRaw(relayFrame(protocol.TypeSDP, `{"sessionId":"`+sid+`","sdpType":"offer","sdp":"`+strings.Repeat("a", 70*1024)+`"}`))
	if host.has(protocol.TypeSDP) || ctrl.count(protocol.TypeError) != 2 {
		t.Fatalf("malformed sdp relayed: %s", ctrl.typesLocked())
	}
	if e := ctrl.lastErr(); len(e.Message) > MaxRelayErrorBytes {
		t.Fatalf("the error echoed %d bytes", len(e.Message))
	}
}

func TestPakeStepsAreIntegersOneToThreeRelayedOnceInOrderByTheirOwnSide(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)
	pake := func(step string) string {
		return relayFrame(protocol.TypePake, `{"sessionId":"`+sid+`","step":`+step+`,"payload":"cA=="}`)
	}
	refused := func(p *peer, frame, name string) {
		t.Helper()
		host.reset()
		ctrl.reset()
		p.sendRaw(frame)
		if host.has(protocol.TypePake) || ctrl.has(protocol.TypePake) || p.lastErr().Code != protocol.ErrBadRequest {
			t.Fatalf("%s was not refused", name)
		}
	}
	for _, step := range []string{"0", "4", "-1", "4294967296", "2147483648", "1.5", "1.0", "1e0", `"1"`, "null"} {
		refused(ctrl, pake(step), "step "+step)
	}
	refused(host, pake("1"), "step 1 from the host")
	refused(ctrl, pake("3"), "step 3 before step 2")
	refused(ctrl, pake("2"), "step 2 from the controller")

	ctrl.sendRaw(pake("1"))
	if got := host.lastPayload(protocol.TypePake); got != `{"sessionId":"`+sid+`","step":1,"payload":"cA=="}` {
		t.Fatalf("step 1 relayed as %s", got)
	}
	refused(ctrl, pake("1"), "a second step 1")
	host.sendRaw(pake("2"))
	if !ctrl.has(protocol.TypePake) {
		t.Fatal("step 2 was not relayed")
	}
	refused(host, pake("2"), "a second step 2")
	ctrl.sendRaw(pake("3"))
	if !host.has(protocol.TypePake) {
		t.Fatal("step 3 was not relayed")
	}
	refused(ctrl, pake("3"), "a second step 3")
}

func TestRelayBeforeMeteringIsBounded(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)
	cand := protocol.ICE{SessionID: sid, Candidate: "candidate:1 1 udp 1 192.0.2.1 9 typ host"}
	for i := 0; i < protocol.MaxUnmeteredICEPerSide; i++ {
		ctrl.send(protocol.TypeICE, cand)
		host.send(protocol.TypeICE, cand)
	}
	host.reset()
	ctrl.reset()
	ctrl.send(protocol.TypeICE, cand)
	host.send(protocol.TypeICE, cand)
	if host.has(protocol.TypeICE) || ctrl.has(protocol.TypeICE) ||
		ctrl.lastErr().Code != protocol.ErrBadRequest || host.lastErr().Code != protocol.ErrBadRequest {
		t.Fatal("candidates beyond the unmetered budget were relayed")
	}
	for i := 0; i < protocol.MaxUnmeteredSDPFromCtrl; i++ {
		ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: "v=0"})
	}
	host.reset()
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: "v=0"})
	if host.has(protocol.TypeSDP) {
		t.Fatal("controller descriptions beyond the unmetered budget were relayed")
	}

	host.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "answer", SDP: "v=0"})
	host.reset()
	ctrl.reset()
	for i := 0; i < 3; i++ {
		ctrl.send(protocol.TypeICE, cand)
		ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: "v=0", Restart: true})
	}
	if host.count(protocol.TypeICE) != 3 || host.count(protocol.TypeSDP) != 3 {
		t.Fatalf("a metered session is still bounded: %s", host.typesLocked())
	}
}

func TestRefusedConnectsChargeNeitherTheControllerNorTheHost(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	busyHost := hn.newPeerAt("203.0.113.5")
	busyHost.register("busy")
	busyHost.hello(protocol.RoleHost)
	other := hn.newPeerAt("203.0.113.6")
	other.register("other")
	other.hello(protocol.RoleController)
	if _, opened := other.connect(busyHost.deviceID); !opened {
		t.Fatal("setup: could not occupy the busy host")
	}
	denied := hn.newPeerAt("203.0.113.7")
	denied.register("denied")
	denied.hello(protocol.RoleHost)
	hn.ent.denyDevice(denied.deviceID, protocol.EntitlementNoBalance)
	offline := hn.newPeerAt("203.0.113.8")
	offline.register("offline")

	for i := 0; i < 5; i++ {
		for target, code := range map[string]string{
			"999999999":       protocol.ErrUnknownDevice,
			offline.deviceID:  protocol.ErrOffline,
			busyHost.deviceID: protocol.ErrBusy,
			denied.deviceID:   protocol.ErrEntitlement,
		} {
			if _, opened := ctrl.connect(target); opened || ctrl.lastErr().Code != code {
				t.Fatalf("connect to %s = %+v, want %s", target, ctrl.lastErr(), code)
			}
		}
	}
	for i := 0; i < protocol.ConnectPerControllerPerMin; i++ {
		ok, opened := ctrl.connect(host.deviceID)
		if !opened {
			t.Fatalf("delivery %d after 20 refusals: %+v", i, ctrl.lastErr())
		}
		ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
	}
	if _, opened := ctrl.connect(host.deviceID); opened || ctrl.lastErr().Code != protocol.ErrRateLimited {
		t.Fatal("the controller budget does not count deliveries")
	}
}

func TestAKnownPairIsNeverBlockedByTheHostBudget(t *testing.T) {
	hn := newHarness(t)
	host, friend := hn.pair(t)
	ok, _ := friend.connect(host.deviceID)
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "answer", SDP: "v=0"})
	friend.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
	hn.ent.awaitReports(t, 1, 1)

	delivered := 0
	var last protocol.Error
	for i := 0; delivered < protocol.ConnectPerHostPerMin+5 && i < 60; i++ {
		c := hn.connectingController(i)
		if s, opened := c.connect(host.deviceID); opened {
			delivered++
			c.send(protocol.TypeBye, protocol.Bye{SessionID: s.SessionID, Reason: protocol.ByeUserEnded})
		} else if last = c.lastErr(); last.Code == protocol.ErrRateLimited {
			break
		}
	}
	if delivered != protocol.ConnectPerHostPerMin-1 || last.Code != protocol.ErrRateLimited {
		t.Fatalf("strangers delivered %d then %+v; want the host budget to stop them", delivered, last)
	}

	hn.hub.mu.Lock()
	hn.hub.knownPairs = map[string]struct{}{}
	hn.hub.mu.Unlock()
	for i := 0; i < protocol.ConnectPerControllerPerMin-1; i++ {
		s, opened := friend.connect(host.deviceID)
		if !opened {
			t.Fatalf("known controller attempt %d after an rc-signal restart: %+v", i, friend.lastErr())
		}
		friend.send(protocol.TypeBye, protocol.Bye{SessionID: s.SessionID, Reason: protocol.ByeUserEnded})
	}
	hn.ent.mu.Lock()
	asks := hn.ent.pairAsks
	hn.ent.mu.Unlock()
	if asks == 0 {
		t.Fatal("the durable pair record was never consulted")
	}

	hn.ent.mu.Lock()
	hn.ent.pairErr = errors.New("rc-api down")
	hn.ent.mu.Unlock()
	stranger := hn.newPeerAt("192.0.2.200")
	stranger.register("stranger")
	stranger.hello(protocol.RoleController)
	if _, opened := stranger.connect(host.deviceID); opened || stranger.lastErr().Code != protocol.ErrRateLimited {
		t.Fatal("a failed pair lookup let a stranger past the host budget")
	}
}

func TestConnectReqIsLimitedPerAddress(t *testing.T) {
	hn := newHarness(t)
	var ctrls []*peer
	for i := 0; i < 6; i++ {
		c := hn.newPeerAt("192.0.2.77")
		c.register(fmt.Sprintf("nat-%d", i))
		c.hello(protocol.RoleController)
		ctrls = append(ctrls, c)
	}
	refused := 0
	for i := 0; i < protocol.ConnectPerIPPerMin+1; i++ {
		c := ctrls[i%len(ctrls)]
		if _, opened := c.connect("999999999"); !opened && c.lastErr().Code == protocol.ErrRateLimited {
			refused = i
			break
		}
	}
	if refused != protocol.ConnectPerIPPerMin {
		t.Fatalf("attempt %d from one address was rate limited, want %d", refused, protocol.ConnectPerIPPerMin)
	}
	elsewhere := hn.controller("elsewhere")
	if _, opened := elsewhere.connect("999999999"); elsewhere.lastErr().Code != protocol.ErrUnknownDevice || opened {
		t.Fatalf("another address was limited too: %+v", elsewhere.lastErr())
	}
}

func TestHelloSignsOnlyAProvedBinding(t *testing.T) {
	hn := newHarness(t)
	owner := hn.newPeer()
	id := owner.register("owner")
	calls := func() int {
		hn.reg.mu.Lock()
		defer hn.reg.mu.Unlock()
		return hn.reg.certifies
	}

	owner.reset()
	owner.send(protocol.TypeHello, protocol.Hello{DeviceID: id, Pubkey: owner.pubB64, Sig: owner.sig(protocol.PurposeHello, true), Role: protocol.RoleHost})
	if owner.lastErr().Code != protocol.ErrBadSignature || calls() != 0 {
		t.Fatalf("a forged hello reached the registry: %d calls", calls())
	}
	stranger := hn.newPeer()
	stranger.helloAs(id, protocol.RoleHost)
	if hello := stranger.lastErr(); hello.Code != protocol.ErrUnknownDevice {
		t.Fatalf("another key's hello = %+v", hello)
	}
	host := hn.newPeer()
	host.register("host")
	host.hello(protocol.RoleHost)
	before := calls()
	ctrl := hn.controller("ctrl")
	for i := 0; i < 3; i++ {
		ctrl.connect(host.deviceID)
	}
	if calls() != before+1 {
		t.Fatalf("connect_req lookups asked for certificates: %d calls", calls()-before)
	}
	if ok := owner.hello(protocol.RoleHost); !hn.authority.Verify(id, owner.pubB64, ok.IDCert) {
		t.Fatal("the proved hello carried no certificate")
	}
}

// rc-api's POST /internal/sessions/close after a sign-out unlinks the host (API.md §3.6).
func TestCloseSessionsForDeviceEndsTheHostsLiveSession(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: "v=0\r\n"})
	hn.ent.awaitReports(t, 1, 0)
	if live := hn.hub.LiveMeteredSessions(); len(live.SessionIDs) != 1 {
		t.Fatalf("live metered sessions = %v, want the open one", live.SessionIDs)
	}

	host.reset()
	ctrl.reset()
	if closed := hn.hub.CloseSessionsForDevice(host.deviceID, protocol.ByeHostEnded); closed != 1 {
		t.Fatalf("closed %d sessions, want 1", closed)
	}
	for name, p := range map[string]*peer{"host": host, "controller": ctrl} {
		b := unmarshal[protocol.Bye](t, p.last(protocol.TypeBye))
		if b.SessionID != sid || b.Reason != protocol.ByeHostEnded {
			t.Fatalf("%s bye = %+v, want host_ended for %s", name, b, sid)
		}
	}
	if got := hn.hub.SessionState(sid); got != "" {
		t.Fatalf("session state after the internal close = %q, want gone", got)
	}
	_, stops := hn.ent.awaitReports(t, 1, 1)
	if stops[0].SessionID != sid || stops[0].Reason != protocol.ByeHostEnded {
		t.Fatalf("stop report = %+v", stops[0])
	}
	if closed := hn.hub.CloseSessionsForDevice(host.deviceID, protocol.ByeHostEnded); closed != 0 {
		t.Fatalf("a second close found %d sessions, want none", closed)
	}
}
