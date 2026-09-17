// Command smokeclient drives two real WebSocket clients through the whole
// rc-signal flow and prints PASS/FAIL per step.
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
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"rc-signal/internal/entitlement"
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

type client struct {
	name     string
	url      string
	ws       *websocket.Conn
	priv     *ecdsa.PrivateKey
	pub      string
	deviceID string
	idCert   string
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

// closedWithin waits for the server to close the socket and returns how long it took, or limit.
func (c *client) closedWithin(limit time.Duration) time.Duration {
	started := time.Now()
	deadline := time.After(limit)
	for {
		select {
		case _, open := <-c.in:
			if !open {
				return time.Since(started)
			}
		case <-deadline:
			c.hangUp()
			return limit
		}
	}
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
	c.sendRaw(string(b))
}

func (c *client) sendRaw(frame string) {
	if err := c.ws.WriteMessage(websocket.TextMessage, []byte(frame)); err != nil {
		fatal("%s: write: %v", c.name, err)
	}
}

func relayFrame(msgType, payload string) string {
	return fmt.Sprintf(`{"v":%d,"type":%q,"id":"raw","payload":%s}`, protocol.Version, msgType, payload)
}

type env struct{ protocol.Envelope }

func (e env) nonce() string {
	var ch protocol.Challenge
	_ = protocol.Unmarshal(e.Envelope, &ch)
	return ch.Nonce
}

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

func (c *client) buffered(typ string) (env, bool) {
	for i, p := range c.pending {
		if p.Type == typ {
			c.pending = append(c.pending[:i:i], c.pending[i+1:]...)
			return env{p}, true
		}
	}
	return env{}, false
}

func (c *client) sig(purpose protocol.SigningPurpose) string {
	nb, err := base64.StdEncoding.DecodeString(c.nonce)
	if err != nil {
		fatal("%s: bad nonce: %v", c.name, err)
	}
	message, err := protocol.SigningMessage(purpose, nb)
	if err != nil {
		fatal("%s: %v", c.name, err)
	}
	sum := sha256.Sum256(message)
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

const (
	legacyCode  = "SW7K2M9Q"
	deniedLabel = entitlement.DevDenyLabel
)

func (c *client) register(label string) string {
	return c.registerAs(label, "", "").DeviceID
}

func (c *client) registerAs(label, preferred, cert string) protocol.RegisterOK {
	c.send(protocol.TypeRegister, protocol.Register{
		Pubkey: c.pub, Sig: c.sig(protocol.PurposeRegister), Label: label,
		PreferredDeviceID: preferred, IDCert: cert})
	e, ok := c.wait(protocol.TypeRegisterOK, protocol.TypeError)
	if !ok || e.Type != protocol.TypeRegisterOK {
		fatal("%s: register failed: %s %+v", c.name, e.Type, decode[protocol.Error](e))
	}
	reg := decode[protocol.RegisterOK](e)
	c.deviceID, c.idCert = reg.DeviceID, reg.IDCert
	c.mustGet(protocol.TypeChallenge)
	return reg
}

func (c *client) tryHello(deviceID, role string) env {
	c.send(protocol.TypeHello, protocol.Hello{
		DeviceID: deviceID, Pubkey: c.pub, Sig: c.sig(protocol.PurposeHello), Role: role})
	e, ok := c.wait(protocol.TypeHelloOK, protocol.TypeError)
	if !ok {
		fatal("%s: no answer to hello", c.name)
	}
	if e.Type == protocol.TypeError {
		c.mustGet(protocol.TypeChallenge)
	}
	return e
}

func (c *client) hello(role string) protocol.HelloOK {
	e := c.tryHello(c.deviceID, role)
	if e.Type == protocol.TypeError {
		fatal("%s: hello failed: %+v", c.name, decode[protocol.Error](e))
	}
	return decode[protocol.HelloOK](e)
}

func (c *client) request(typ string, payload any, want string) (env, protocol.Error) {
	c.send(typ, payload)
	e, ok := c.wait(want, protocol.TypeError)
	if !ok {
		fatal("%s: no answer to %s", c.name, typ)
	}
	var er protocol.Error
	if e.Type == protocol.TypeError {
		er = decode[protocol.Error](e)
	}
	return e, er
}

func sessionTURN(servers []protocol.ICEServer, sessionID string) bool {
	for _, s := range servers {
		if s.Credential != "" && strings.HasSuffix(s.Username, ":"+sessionID) {
			return true
		}
	}
	return false
}

func anyCredential(servers []protocol.ICEServer) bool {
	for _, s := range servers {
		if s.Credential != "" || s.Username != "" {
			return true
		}
	}
	return false
}

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

	hostID := host.register("Smoke Host")
	ctrlID := ctrl.register("Smoke Controller")
	check("register host device", protocol.ValidDeviceID(hostID),
		fmt.Sprintf("deviceId %q is not 9 digits", hostID))
	check("register controller device",
		protocol.ValidDeviceID(ctrlID) && ctrlID != hostID,
		fmt.Sprintf("controller id %q vs host id %q", ctrlID, hostID))
	check("register_ok carries a device-id certificate", host.idCert != "" && ctrl.idCert != "",
		fmt.Sprintf("host=%q ctrl=%q", host.idCert, ctrl.idCert))

	e, er := host.request(protocol.TypeRegister, protocol.Register{
		Pubkey: host.pub, Sig: host.sig(protocol.PurposeRegister)}, protocol.TypeRegisterOK)
	check("a second register on one connection is refused",
		e.Type == protocol.TypeError && er.Code == protocol.ErrBadRequest, fmt.Sprintf("got %s %+v", e.Type, er))

	hok := host.hello(protocol.RoleHost)
	cok := ctrl.hello(protocol.RoleController)
	check("host hello_ok", hok.DeviceID == hostID && hok.HeartbeatSec == 15 && hok.OfflineAfterSec == 40 && hok.IDCert != "",
		fmt.Sprintf("%+v", hok))
	check("hello_ok carries no TURN credentials", len(cok.ICEServers) > 0 && !anyCredential(cok.ICEServers),
		fmt.Sprintf("iceServers = %+v", cok.ICEServers))

	prober := newClient("prober", url)
	prober.dial()
	takenAns := prober.tryHello(hostID, protocol.RoleHost)
	freeAns := prober.tryHello("123456789", protocol.RoleHost)
	check("hello answers a taken id and a free id identically",
		takenAns.Type == protocol.TypeError && decode[protocol.Error](takenAns) == decode[protocol.Error](freeAns) &&
			decode[protocol.Error](takenAns).Code == protocol.ErrUnknownDevice,
		fmt.Sprintf("taken=%+v free=%+v", decode[protocol.Error](takenAns), decode[protocol.Error](freeAns)))
	squat := prober.registerAs("Smoke Squatter", hostID, host.idCert)
	check("another key's certificate does not claim an id", squat.DeviceID != hostID && !squat.Existing,
		fmt.Sprintf("got %+v", squat))
	prober.hangUp()

	e, er = host.request(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: ctrlID}, protocol.TypeConnectOK)
	check("connect_req from a host connection is forbidden",
		e.Type == protocol.TypeError && er.Code == protocol.ErrForbidden, fmt.Sprintf("got %s %+v", e.Type, er))

	host.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	hb := decode[protocol.HeartbeatOK](host.mustGet(protocol.TypeHeartbeatOK))
	check("heartbeat acknowledged", hb.ServerTime > 0, fmt.Sprintf("serverTime = %d", hb.ServerTime))

	ctrl.send(protocol.TypeWatch, protocol.Watch{DeviceID: hostID})
	wok := decode[protocol.WatchOK](ctrl.mustGet(protocol.TypeWatchOK))
	pres := decode[protocol.Presence](ctrl.mustGet(protocol.TypePresence))
	check("watch reports the host online", wok.DeviceID == hostID && pres.Online && pres.DeviceID == hostID,
		fmt.Sprintf("watch_ok=%+v presence=%+v", wok, pres))

	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID, AccessCode: legacyCode})
	e, _ = ctrl.wait(protocol.TypeConnectOK, protocol.TypeError)
	errp := decode[protocol.Error](e)
	check("connect_req carrying an access code is rejected with bad_request",
		e.Type == protocol.TypeError && errp.Code == protocol.ErrBadRequest,
		fmt.Sprintf("got %s %+v", e.Type, errp))

	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID})
	e, ok := ctrl.wait(protocol.TypeConnectOK, protocol.TypeError)
	if !ok || e.Type != protocol.TypeConnectOK {
		fatal("an entitled host refused the connection: %s %+v", e.Type, decode[protocol.Error](e))
	}
	conn := decode[protocol.ConnectOK](e)
	ctrl.session, ctrl.token = conn.SessionID, conn.SessionToken
	start := decode[protocol.SessionStart](host.mustGet(protocol.TypeSessionStart))
	host.session, host.token = start.SessionID, start.SessionToken
	check("connect_req opens a session without any access code",
		len(conn.SessionID) == 32 && conn.HostDeviceID == hostID && conn.ControllerDeviceID == ctrlID,
		fmt.Sprintf("%+v", conn))
	check("host is told about the session with its own token",
		start.SessionID == conn.SessionID && start.SessionToken != "" && start.SessionToken != conn.SessionToken,
		fmt.Sprintf("host=%+v", start))
	check("each side is told which device key must sign the other's SDP",
		conn.HostPubkey == host.pub && start.HostPubkey == host.pub,
		fmt.Sprintf("connect_ok=%q session_start=%q", conn.HostPubkey, start.HostPubkey))
	check("the host is told the controller's key, which its guess policy is keyed on",
		start.ControllerPubkey == ctrl.pub,
		fmt.Sprintf("session_start controllerPubkey=%q", start.ControllerPubkey))
	check("connect_ok and session_start carry STUN only, no TURN before metering",
		len(conn.ICEServers) > 0 && !anyCredential(conn.ICEServers) && !anyCredential(start.ICEServers),
		fmt.Sprintf("connect_ok=%+v session_start=%+v", conn.ICEServers, start.ICEServers))

	ctrl.sendRaw(relayFrame(protocol.TypeICE, `{"sessionId":"ffffffffffffffffffffffffffffffff","SESSIONID":"`+ctrl.session+`","candidate":""}`))
	e, _ = ctrl.wait(protocol.TypeError)
	caseVariant := decode[protocol.Error](e)
	ctrl.sendRaw(relayFrame(protocol.TypeICE, `{"sessionId":"`+ctrl.session+`","candidate":"","sdp":"v=0 smuggled","sdpType":"offer"}`))
	e, _ = ctrl.wait(protocol.TypeError)
	smuggled := decode[protocol.Error](e)
	ctrl.sendRaw(relayFrame(protocol.TypePake, `{"sessionId":"`+ctrl.session+`","step":4294967296,"payload":"cA=="}`))
	e, _ = ctrl.wait(protocol.TypeError)
	hugeStep := decode[protocol.Error](e)
	_, hostSawICE := host.buffered(protocol.TypeICE)
	_, hostSawPake := host.buffered(protocol.TypePake)
	check("relayed payloads outside their exact schema are refused and never relayed",
		caseVariant.Code == protocol.ErrBadRequest && smuggled.Code == protocol.ErrBadRequest &&
			hugeStep.Code == protocol.ErrBadRequest && !hostSawICE && !hostSawPake,
		fmt.Sprintf("case=%+v smuggled=%+v step=%+v relayedICE=%v relayedPake=%v", caseVariant, smuggled, hugeStep, hostSawICE, hostSawPake))

	e, er = ctrl.request(protocol.TypeBye, protocol.Bye{SessionID: ctrl.session, Reason: strings.Repeat("A", 70*1024)}, protocol.TypeBye)
	_, hostSawBye := host.buffered(protocol.TypeBye)
	check("a bye with an undefined reason is refused and not relayed",
		e.Type == protocol.TypeError && er.Code == protocol.ErrBadRequest && !hostSawBye,
		fmt.Sprintf("got %s %+v host bye=%v", e.Type, er, hostSawBye))

	third := newClient("ctrl2", url)
	third.dial()
	third.register("Smoke Controller 2")
	third.hello(protocol.RoleController)
	third.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID})
	e, _ = third.wait(protocol.TypeConnectOK, protocol.TypeError)
	busy := decode[protocol.Error](e)
	check("second controller is rejected with busy",
		e.Type == protocol.TypeError && busy.Code == protocol.ErrBusy,
		fmt.Sprintf("got %s %+v", e.Type, busy))
	third.hangUp()

	const offerSDP = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: ctrl.session, SDPType: "offer", SDP: offerSDP})
	got := decode[protocol.SDP](host.mustGet(protocol.TypeSDP))
	check("SDP offer relayed to the host verbatim",
		got.SDP == offerSDP && got.SDPType == "offer" && got.SessionID == ctrl.session,
		fmt.Sprintf("got %+v", got))

	const answerSDP = offerSDP + "a=recvonly\r\n"
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: host.session, SDPType: "answer", SDP: answerSDP})
	ctrlTURN := decode[protocol.ICEServers](ctrl.mustGet(protocol.TypeICEServers))
	ans := decode[protocol.SDP](ctrl.mustGet(protocol.TypeSDP))
	check("SDP answer relayed to the controller verbatim",
		ans.SDP == answerSDP && ans.SDPType == "answer",
		fmt.Sprintf("got %+v", ans))
	hostTURN := decode[protocol.ICEServers](host.mustGet(protocol.TypeICEServers))
	check("the host's first sdp pushes session TURN (ice_servers) to both peers",
		ctrlTURN.SessionID == ctrl.session && sessionTURN(ctrlTURN.ICEServers, ctrl.session) &&
			sessionTURN(hostTURN.ICEServers, ctrl.session),
		fmt.Sprintf("controller=%+v host=%+v", ctrlTURN, hostTURN))

	cand := "candidate:1 1 udp 2113937151 192.0.2.1 54321 typ host"
	ctrl.send(protocol.TypeICE, protocol.ICE{SessionID: ctrl.session, Candidate: cand, SDPMid: "0"})
	ice := decode[protocol.ICE](host.mustGet(protocol.TypeICE))
	check("ICE candidate relayed", ice.Candidate == cand && ice.SDPMid == "0",
		fmt.Sprintf("got %+v", ice))

	pakeOne := base64.StdEncoding.EncodeToString([]byte("spake2-message-one"))
	ctrl.send(protocol.TypePake, protocol.Pake{SessionID: ctrl.session, Step: 1, Payload: pakeOne})
	pk := decode[protocol.Pake](host.mustGet(protocol.TypePake))
	check("pake step 1 relayed to the host verbatim",
		pk.Payload == pakeOne && pk.Step == 1 && pk.SessionID == ctrl.session,
		fmt.Sprintf("got %+v", pk))

	pakeTwo := base64.StdEncoding.EncodeToString([]byte("spake2-message-two"))
	host.send(protocol.TypePake, protocol.Pake{SessionID: host.session, Step: 2, Payload: pakeTwo})
	pk2 := decode[protocol.Pake](ctrl.mustGet(protocol.TypePake))
	check("pake step 2 relayed back to the controller",
		pk2.Payload == pakeTwo && pk2.Step == 2,
		fmt.Sprintf("got %+v", pk2))

	oversize := strings.Repeat("A", protocol.MaxPakePayloadBytes+4)
	ctrl.send(protocol.TypePake, protocol.Pake{SessionID: ctrl.session, Step: 3, Payload: oversize})
	e, _ = ctrl.wait(protocol.TypeError)
	big := decode[protocol.Error](e)
	check("an oversized pake payload is rejected with bad_request",
		e.Type == protocol.TypeError && big.Code == protocol.ErrBadRequest,
		fmt.Sprintf("got %s %+v", e.Type, big))

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
	check("resume re-attaches without any access code",
		rok.SessionID == ctrl.session && rok.PeerAttached && rok.Role == protocol.RoleController,
		fmt.Sprintf("%+v", rok))
	check("resume rotates the session token", rok.SessionToken != ctrl.token, "token unchanged")
	resumed.session, resumed.token = rok.SessionID, rok.SessionToken

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

	host.send(protocol.TypeSDP, protocol.SDP{SessionID: host.session, SDPType: "offer", SDP: offerSDP, Restart: true})
	rst := decode[protocol.SDP](live.mustGet(protocol.TypeSDP))
	check("ICE-restart offer relays after resume",
		rst.SDP == offerSDP && rst.Restart, fmt.Sprintf("got %+v", rst))

	e, er = live.request(protocol.TypeRenew, protocol.Renew{SessionID: live.session, SessionToken: live.token}, protocol.TypeRenewOK)
	if e.Type == protocol.TypeRenewOK {
		renewed := decode[protocol.RenewOK](e)
		live.token = renewed.SessionToken
		check("renew_ok carries fresh session TURN credentials", sessionTURN(renewed.ICEServers, live.session),
			fmt.Sprintf("iceServers = %+v", renewed.ICEServers))
	} else {
		check("renew_ok carries fresh session TURN credentials", false, fmt.Sprintf("got %+v", er))
	}

	host.send(protocol.TypeRefreshCode, map[string]any{})
	rc := decode[protocol.RefreshCodeOK](host.mustGet(protocol.TypeRefreshCodeOK))
	check("refresh_code acknowledged with an empty payload", rc.DeviceID == hostID, fmt.Sprintf("%+v", rc))

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

	live.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: hostID})
	e, ok = live.wait(protocol.TypeConnectOK, protocol.TypeError)
	check("a fresh session opens after the refresh",
		ok && e.Type == protocol.TypeConnectOK,
		fmt.Sprintf("got %s %+v", e.Type, decode[protocol.Error](e)))
	if e.Type == protocol.TypeConnectOK {
		live.session = decode[protocol.ConnectOK](e).SessionID
		host.session = decode[protocol.SessionStart](host.mustGet(protocol.TypeSessionStart)).SessionID
	}

	live.send(protocol.TypeBye, protocol.Bye{SessionID: live.session, Reason: protocol.ByeUserEnded})
	hb2, ok := host.wait(protocol.TypeBye)
	check("bye closes the session for both sides",
		ok && decode[protocol.Bye](hb2).SessionID == live.session,
		fmt.Sprintf("host bye = %+v", decode[protocol.Bye](hb2)))

	denied := newClient("denied-host", url)
	denied.dial()
	deniedID := denied.register(deniedLabel)
	denied.hello(protocol.RoleHost)
	live.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: deniedID})
	e, _ = live.wait(protocol.TypeConnectOK, protocol.TypeError)
	de := decode[protocol.Error](e)
	check("a host the entitlement denies gets error{entitlement} with a reason",
		e.Type == protocol.TypeError && de.Code == protocol.ErrEntitlement && de.Reason != "",
		fmt.Sprintf("got %s %+v", e.Type, de))
	denied.hangUp()

	live.send(protocol.TypeWatch, protocol.Watch{DeviceID: hostID})
	live.mustGet(protocol.TypeWatchOK)
	live.mustGet(protocol.TypePresence)
	host.hangUp()
	off, ok := live.wait(protocol.TypePresence)
	ov := decode[protocol.Presence](off)
	check("presence flips to offline when the host socket dies",
		ok && !ov.Online && ov.DeviceID == hostID, fmt.Sprintf("presence = %+v", ov))
	if _, dup := live.buffered(protocol.TypePresence); dup {
		check("no duplicate presence pushes", false, "more than one presence event for a single change")
	}
	live.hangUp()

	back := newClient("host-again", url)
	back.priv, back.pub = host.priv, host.pub
	back.dial()
	again := back.registerAs("Smoke Host", hostID, host.idCert)
	check("re-register with its own certificate keeps the id",
		again.DeviceID == hostID && again.Existing && again.IDCert != "", fmt.Sprintf("got %+v", again))
	back.hangUp()

	burst := newClient("burst", url)
	burst.dial()
	burst.register("Smoke Burst")
	burst.hello(protocol.RoleController)
	var limited protocol.Error
	for i := 0; i <= protocol.ConnectPerIPPerMin && limited.Code == ""; i++ {
		if _, er := burst.request(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: "123456789"}, protocol.TypeConnectOK); er.Code == protocol.ErrRateLimited {
			limited = er
		}
	}
	check("connect_req bursts from one address are refused with rate_limited and retryAfterSec",
		limited.Code == protocol.ErrRateLimited && limited.RetryAfterSec > 0, fmt.Sprintf("got %+v", limited))
	burst.hangUp()

	idle := newClient("idle", url)
	idle.dial()
	started := time.Now()
	closedAfter := idle.closedWithin(protocol.AuthTimeoutSec*time.Second + 10*time.Second)
	check("an unauthenticated socket is closed after the auth timeout",
		closedAfter >= protocol.AuthTimeoutSec*time.Second && closedAfter <= protocol.AuthTimeoutSec*time.Second+7*time.Second,
		fmt.Sprintf("closed after %s (started %s)", closedAfter, started.Format(time.TimeOnly)))

	fmt.Printf("\n%d/%d steps passed\n", steps-failures, steps)
	if failures > 0 {
		os.Exit(1)
	}
}
