// Command smokeclient drives two real WebSocket clients through the whole
// rc-signal flow and prints PASS/FAIL per step. It exits non-zero if any step
// fails. It is used by scripts/smoke-signal.sh; there is no other runtime
// dependency.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/gorilla/websocket"

	"rc-signal/internal/auth"
	"rcprotocol"
)

var (
	failures int
	steps    int
)

func check(name string, ok bool, detail string) {
	steps++
	if ok {
		fmt.Printf("PASS  %s\n", name)
		return
	}
	failures++
	fmt.Printf("FAIL  %s\n      %s\n", name, detail)
}

func fatal(format string, args ...any) {
	fmt.Printf("FAIL  fatal: "+format+"\n", args...)
	os.Exit(1)
}

// ---------------------------------------------------------------------------

type client struct {
	name     string
	url      string
	ws       *websocket.Conn
	priv     *ecdsa.PrivateKey
	pub      string
	deviceID string
	token    string
	session  string

	in      chan protocol.Envelope
	pending []protocol.Envelope
	nonce   string
	dead    chan struct{}
}

func newClient(name, url string) *client {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		fatal("keygen: %v", err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		fatal("spki: %v", err)
	}
	return &client{name: name, url: url, priv: priv,
		pub: base64.StdEncoding.EncodeToString(spki)}
}

func (c *client) dial() {
	dialer := *websocket.DefaultDialer
	if insecureTLS {
		// Self-signed cert, pinned by fingerprint in the real app. The smoke client
		// checks the pin separately; skipping CA verification here is deliberate.
		dialer.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	ws, _, err := dialer.Dial(c.url, nil)
	if err != nil {
		fatal("%s: dial %s: %v", c.name, c.url, err)
	}
	c.ws = ws
	c.in = make(chan protocol.Envelope, 64)
	c.pending = nil
	c.dead = make(chan struct{})
	go func() {
		defer close(c.dead)
		for {
			_, data, err := ws.ReadMessage()
			if err != nil {
				close(c.in)
				return
			}
			e, err := protocol.Decode(data)
			if err != nil {
				fatal("%s: undecodable frame: %v", c.name, err)
			}
			c.in <- e
		}
	}()
	c.nonce = c.mustGet(protocol.TypeChallenge).nonce()
}

func (c *client) hangUp() {
	_ = c.ws.Close()
	<-c.dead
}

func (c *client) send(typ string, payload any) {
	b, err := protocol.Encode(typ, "s", "", time.Now().UnixMilli(), payload)
	if err != nil {
		fatal("%s: encode %s: %v", c.name, typ, err)
	}
	if err := c.ws.WriteMessage(websocket.TextMessage, b); err != nil {
		fatal("%s: write %s: %v", c.name, typ, err)
	}
}

type env struct{ protocol.Envelope }

func (e env) nonce() string {
	var ch protocol.Challenge
	_ = protocol.Unmarshal(e.Envelope, &ch)
	return ch.Nonce
}

// wait returns the next message whose type is in want, buffering the rest.
func (c *client) wait(want ...string) (env, bool) {
	match := func(t string) bool {
		for _, w := range want {
			if w == t {
				return true
			}
		}
		return false
	}
	for i, p := range c.pending {
		if match(p.Type) {
			c.pending = append(c.pending[:i:i], c.pending[i+1:]...)
			return env{p}, true
		}
	}
	deadline := time.After(8 * time.Second)
	for {
		select {
		case e, ok := <-c.in:
			if !ok {
				return env{}, false
			}
			if e.Type == protocol.TypeChallenge {
				c.nonce = env{e}.nonce()
			}
			if match(e.Type) {
				return env{e}, true
			}
			c.pending = append(c.pending, e)
		case <-deadline:
			return env{}, false
		}
	}
}

func (c *client) mustGet(want string) env {
	e, ok := c.wait(want)
	if !ok {
		fatal("%s: timed out waiting for %s", c.name, want)
	}
	return e
}

// drain returns any already-buffered message of the given type.
func (c *client) buffered(typ string) (env, bool) {
	for i, p := range c.pending {
		if p.Type == typ {
			c.pending = append(c.pending[:i:i], c.pending[i+1:]...)
			return env{p}, true
		}
	}
	return env{}, false
}

func (c *client) sig() string {
	nb, err := base64.StdEncoding.DecodeString(c.nonce)
	if err != nil {
		fatal("%s: bad nonce: %v", c.name, err)
	}
	sum := sha256.Sum256(nb)
	sig, err := ecdsa.SignASN1(rand.Reader, c.priv, sum[:])
	if err != nil {
		fatal("%s: sign: %v", c.name, err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

func decode[T any](e env) T {
	var v T
	if err := protocol.Unmarshal(e.Envelope, &v); err != nil {
		fatal("decoding %s: %v", e.Type, err)
	}
	return v
}

func (c *client) register(label, code string) string {
	v, err := auth.MakeVerifier(code)
	if err != nil {
		fatal("verifier: %v", err)
	}
	c.send(protocol.TypeRegister, protocol.Register{
		Pubkey: c.pub, Sig: c.sig(), Label: label, Code: v})
	ok := decode[protocol.RegisterOK](c.mustGet(protocol.TypeRegisterOK))
	c.deviceID = ok.DeviceID
	c.mustGet(protocol.TypeChallenge) // fresh nonce for hello
	return ok.DeviceID
}

func (c *client) hello(role string) protocol.HelloOK {
	c.send(protocol.TypeHello, protocol.Hello{
		DeviceID: c.deviceID, Pubkey: c.pub, Sig: c.sig(), Role: role})
	e, ok := c.wait(protocol.TypeHelloOK, protocol.TypeError)
	if !ok || e.Type == protocol.TypeError {
		fatal("%s: hello failed: %v", c.name, e.Type)
	}
	return decode[protocol.HelloOK](e)
}

// ---------------------------------------------------------------------------

const (
	hostCode = "SW7K2M9Q"
	newCode  = "TQ4X8B2N"
)

var insecureTLS bool

func main() {
	addr := flag.String("addr", "127.0.0.1:18443", "rc-signal address")
	useTLS := flag.Bool("tls", false, "connect with wss:// and skip CA verification (self-signed)")
	flag.Parse()
	insecureTLS = *useTLS
	scheme := "ws://"
	if *useTLS {
		scheme = "wss://"
	}
	url := scheme + *addr + "/ws"

	host := newClient("host", url)
	ctrl := newClient("ctrl", url)
	host.dial()
	ctrl.dial()

	// ---- 1. registration -------------------------------------------------
	hostID := host.register("Smoke Host", hostCode)
	ctrlID := ctrl.register("Smoke Controller", "CTRLCODE")
	check("register host device", protocol.ValidDeviceID(hostID),
		fmt.Sprintf("deviceId %q is not 9 digits", hostID))
	check("register controller device",
		protocol.ValidDeviceID(ctrlID) && ctrlID != hostID,
		fmt.Sprintf("controller id %q vs host id %q", ctrlID, hostID))

	// ---- 2. authenticated hello -----------------------------------------
	hok := host.hello(protocol.RoleHost)
	cok := ctrl.hello(protocol.RoleController)
	check("host hello_ok", hok.DeviceID == hostID && hok.HeartbeatSec == 15 && hok.OfflineAfterSec == 40,
		fmt.Sprintf("%+v", hok))
	turnOK := false
	for _, s := range cok.ICEServers {
		if s.Username != "" && s.Credential != "" {
			turnOK = true
		}
	}
	check("hello_ok carries ephemeral TURN credentials", turnOK,
		fmt.Sprintf("iceServers = %+v", cok.ICEServers))

	// ---- 3. heartbeat ----------------------------------------------------
	host.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	hb := decode[protocol.HeartbeatOK](host.mustGet(protocol.TypeHeartbeatOK))
	check("heartbeat acknowledged", hb.ServerTime > 0, fmt.Sprintf("serverTime = %d", hb.ServerTime))

	// ---- 4. presence watch ----------------------------------------------
	ctrl.send(protocol.TypeWatch, protocol.Watch{DeviceID: hostID})
	wok := decode[protocol.WatchOK](ctrl.mustGet(protocol.TypeWatchOK))
	pres := decode[protocol.Presence](ctrl.mustGet(protocol.TypePresence))
	check("watch reports the host online", wok.DeviceID == hostID && pres.Online && pres.DeviceID == hostID,
		fmt.Sprintf("watch_ok=%+v presence=%+v", wok, pres))

	// ---- 5. wrong access code -------------------------------------------
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: "WRONGXXX"})
	e, _ := ctrl.wait(protocol.TypeConnectOK, protocol.TypeError)
	errp := decode[protocol.Error](e)
	check("wrong access code is rejected with bad_code",
		e.Type == protocol.TypeError && errp.Code == protocol.ErrBadCode,
		fmt.Sprintf("got %s %+v", e.Type, errp))

	// ---- 6. correct access code -----------------------------------------
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: hostCode})
	e, ok := ctrl.wait(protocol.TypeConnectOK, protocol.TypeError)
	if !ok || e.Type != protocol.TypeConnectOK {
		fatal("correct access code was rejected: %s %+v", e.Type, decode[protocol.Error](e))
	}
	conn := decode[protocol.ConnectOK](e)
	ctrl.session, ctrl.token = conn.SessionID, conn.SessionToken
	start := decode[protocol.SessionStart](host.mustGet(protocol.TypeSessionStart))
	host.session, host.token = start.SessionID, start.SessionToken
	check("correct access code opens a session",
		len(conn.SessionID) == 32 && conn.HostDeviceID == hostID && conn.ControllerDeviceID == ctrlID,
		fmt.Sprintf("%+v", conn))
	check("host is told about the session with its own token",
		start.SessionID == conn.SessionID && start.SessionToken != "" && start.SessionToken != conn.SessionToken,
		fmt.Sprintf("host=%+v", start))

	// ---- 7. strict 1:1 ---------------------------------------------------
	third := newClient("ctrl2", url)
	third.dial()
	third.register("Smoke Controller 2", "OTHERCOD")
	third.hello(protocol.RoleController)
	third.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: hostCode})
	e, _ = third.wait(protocol.TypeConnectOK, protocol.TypeError)
	busy := decode[protocol.Error](e)
	check("second controller is rejected with busy",
		e.Type == protocol.TypeError && busy.Code == protocol.ErrBusy,
		fmt.Sprintf("got %s %+v", e.Type, busy))
	third.hangUp()

	// ---- 8. SDP / ICE relay ---------------------------------------------
	const offerSDP = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: ctrl.session, SDPType: "offer", SDP: offerSDP})
	got := decode[protocol.SDP](host.mustGet(protocol.TypeSDP))
	check("SDP offer relayed to the host verbatim",
		got.SDP == offerSDP && got.SDPType == "offer" && got.SessionID == ctrl.session,
		fmt.Sprintf("got %+v", got))

	const answerSDP = offerSDP + "a=recvonly\r\n"
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: host.session, SDPType: "answer", SDP: answerSDP})
	ans := decode[protocol.SDP](ctrl.mustGet(protocol.TypeSDP))
	check("SDP answer relayed to the controller verbatim",
		ans.SDP == answerSDP && ans.SDPType == "answer",
		fmt.Sprintf("got %+v", ans))

	cand := "candidate:1 1 udp 2113937151 192.0.2.1 54321 typ host"
	ctrl.send(protocol.TypeICE, protocol.ICE{SessionID: ctrl.session, Candidate: cand, SDPMid: "0"})
	ice := decode[protocol.ICE](host.mustGet(protocol.TypeICE))
	check("ICE candidate relayed", ice.Candidate == cand && ice.SDPMid == "0",
		fmt.Sprintf("got %+v", ice))

	// ---- 9. kill the controller socket and resume ------------------------
	ctrl.hangUp()
	ps, ok := host.wait(protocol.TypePeerState)
	psv := decode[protocol.PeerState](ps)
	check("host sees the peer detach", ok && !psv.Attached && psv.SessionID == host.session,
		fmt.Sprintf("peer_state = %+v", psv))

	resumed := newClient("ctrl-resumed", url)
	resumed.priv, resumed.pub, resumed.deviceID = ctrl.priv, ctrl.pub, ctrl.deviceID
	resumed.dial()
	rhok := resumed.hello(protocol.RoleController)
	check("hello_ok advertises the still-live session",
		rhok.ActiveSessionID == ctrl.session,
		fmt.Sprintf("activeSessionId = %q, want %q", rhok.ActiveSessionID, ctrl.session))

	resumed.send(protocol.TypeResume, protocol.Resume{SessionID: ctrl.session, SessionToken: ctrl.token})
	e, ok = resumed.wait(protocol.TypeResumeOK, protocol.TypeError)
	if !ok || e.Type != protocol.TypeResumeOK {
		fatal("resume failed: %s %+v", e.Type, decode[protocol.Error](e))
	}
	rok := decode[protocol.ResumeOK](e)
	check("resume re-attaches without the access code",
		rok.SessionID == ctrl.session && rok.PeerAttached && rok.Role == protocol.RoleController,
		fmt.Sprintf("%+v", rok))
	check("resume rotates the session token", rok.SessionToken != ctrl.token, "token unchanged")
	resumed.session, resumed.token = rok.SessionID, rok.SessionToken

	// A stale token must now be refused.
	stale := newClient("ctrl-stale", url)
	stale.priv, stale.pub, stale.deviceID = ctrl.priv, ctrl.pub, ctrl.deviceID
	stale.dial()
	stale.hello(protocol.RoleController)
	stale.send(protocol.TypeResume, protocol.Resume{SessionID: ctrl.session, SessionToken: ctrl.token})
	e, _ = stale.wait(protocol.TypeResumeOK, protocol.TypeError)
	se := decode[protocol.Error](e)
	check("the rotated-away token no longer resumes",
		e.Type == protocol.TypeError && se.Code == protocol.ErrBadToken,
		fmt.Sprintf("got %s %+v", e.Type, se))
	stale.hangUp()
	// stale's hello displaced `resumed`; bring the real controller back.
	resumed.hangUp()
	live := newClient("ctrl-live", url)
	live.priv, live.pub, live.deviceID = ctrl.priv, ctrl.pub, ctrl.deviceID
	live.dial()
	live.hello(protocol.RoleController)
	live.send(protocol.TypeResume, protocol.Resume{SessionID: ctrl.session, SessionToken: resumed.token})
	e, ok = live.wait(protocol.TypeResumeOK, protocol.TypeError)
	if !ok || e.Type != protocol.TypeResumeOK {
		fatal("second resume failed: %s %+v", e.Type, decode[protocol.Error](e))
	}
	live.session = ctrl.session
	live.token = decode[protocol.ResumeOK](e).SessionToken

	// ---- 10. relay still works after the resume --------------------------
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: host.session, SDPType: "offer", SDP: offerSDP, Restart: true})
	rst := decode[protocol.SDP](live.mustGet(protocol.TypeSDP))
	check("ICE-restart offer relays after resume",
		rst.SDP == offerSDP && rst.Restart, fmt.Sprintf("got %+v", rst))

	// ---- 11. access-code refresh ----------------------------------------
	v, err := auth.MakeVerifier(newCode)
	if err != nil {
		fatal("verifier: %v", err)
	}
	host.send(protocol.TypeRefreshCode, v)
	rc := decode[protocol.RefreshCodeOK](host.mustGet(protocol.TypeRefreshCodeOK))
	check("refresh_code acknowledged", rc.DeviceID == hostID, fmt.Sprintf("%+v", rc))

	hostBye, hostGotBye := host.wait(protocol.TypeBye)
	check("the host is also told its session ended",
		hostGotBye && decode[protocol.Bye](hostBye).Reason == protocol.ByeCodeRefreshed,
		fmt.Sprintf("host bye = %+v", decode[protocol.Bye](hostBye)))

	bye, ok := live.wait(protocol.TypeBye)
	bv := decode[protocol.Bye](bye)
	check("refresh closes the live session with code_refreshed",
		ok && bv.Reason == protocol.ByeCodeRefreshed && bv.SessionID == ctrl.session,
		fmt.Sprintf("bye = %+v", bv))

	live.send(protocol.TypeResume, protocol.Resume{SessionID: ctrl.session, SessionToken: live.token})
	e, _ = live.wait(protocol.TypeResumeOK, protocol.TypeError)
	re := decode[protocol.Error](e)
	check("the pre-refresh session token is dead",
		e.Type == protocol.TypeError && re.Code == protocol.ErrNoSession,
		fmt.Sprintf("got %s %+v", e.Type, re))

	live.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: hostCode})
	e, _ = live.wait(protocol.TypeConnectOK, protocol.TypeError)
	oe := decode[protocol.Error](e)
	check("the OLD access code now fails with bad_code",
		e.Type == protocol.TypeError && oe.Code == protocol.ErrBadCode,
		fmt.Sprintf("got %s %+v", e.Type, oe))

	live.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: newCode})
	e, ok = live.wait(protocol.TypeConnectOK, protocol.TypeError)
	check("the NEW access code opens a session",
		ok && e.Type == protocol.TypeConnectOK,
		fmt.Sprintf("got %s %+v", e.Type, decode[protocol.Error](e)))
	if e.Type == protocol.TypeConnectOK {
		live.session = decode[protocol.ConnectOK](e).SessionID
		host.session = decode[protocol.SessionStart](host.mustGet(protocol.TypeSessionStart)).SessionID
	}

	// Close it again so the rate-limit probe below is not answered with busy.
	live.send(protocol.TypeBye, protocol.Bye{SessionID: live.session, Reason: protocol.ByeUserEnded})
	hb2, ok := host.wait(protocol.TypeBye)
	check("bye closes the session for both sides",
		ok && decode[protocol.Bye](hb2).SessionID == live.session,
		fmt.Sprintf("host bye = %+v", decode[protocol.Bye](hb2)))

	// ---- 12. rate limiting ----------------------------------------------
	rl := newClient("ctrl-rl", url)
	rl.dial()
	rl.register("Rate Limit Probe", "PROBECOD")
	rl.hello(protocol.RoleController)
	var lastCode string
	var retryAfter int
	for i := 1; i <= 6; i++ {
		rl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: "NOPENOPE"})
		e, _ := rl.wait(protocol.TypeConnectOK, protocol.TypeError)
		ep := decode[protocol.Error](e)
		lastCode, retryAfter = ep.Code, ep.RetryAfterSec
		if i <= 5 && ep.Code != protocol.ErrBadCode {
			check(fmt.Sprintf("attempt %d returns bad_code", i), false, "got "+ep.Code)
		}
	}
	check("the 6th failed attempt is rate_limited",
		lastCode == protocol.ErrRateLimited && retryAfter > 0,
		fmt.Sprintf("code=%s retryAfterSec=%d", lastCode, retryAfter))
	rl.hangUp()

	// ---- 13. presence flips offline when a socket dies -------------------
	// live is watching nothing; make it watch the host, then kill the host.
	live.send(protocol.TypeWatch, protocol.Watch{DeviceID: hostID})
	live.mustGet(protocol.TypeWatchOK)
	live.mustGet(protocol.TypePresence) // current state: online
	host.hangUp()
	off, ok := live.wait(protocol.TypePresence)
	ov := decode[protocol.Presence](off)
	check("presence flips to offline when the host socket dies",
		ok && !ov.Online && ov.DeviceID == hostID, fmt.Sprintf("presence = %+v", ov))
	if _, dup := live.buffered(protocol.TypePresence); dup {
		check("no duplicate presence pushes", false, "more than one presence event for a single change")
	}
	live.hangUp()

	fmt.Printf("\n%d/%d steps passed\n", steps-failures, steps)
	if failures > 0 {
		os.Exit(1)
	}
}
