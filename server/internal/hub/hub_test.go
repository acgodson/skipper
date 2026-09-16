package hub

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/argon2"

	"rc-signal/internal/auth"
	"rc-signal/internal/clockx"
	"rc-signal/internal/store"
	"rcprotocol"
)

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

// fastVerifier builds an Argon2id verifier with the cheapest parameters the
// protocol permits, so tests stay fast while exercising the real code path.
func fastVerifier(t *testing.T, code string) protocol.CodeVerifier {
	t.Helper()
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		t.Fatal(err)
	}
	v := protocol.CodeVerifier{
		Alg: protocol.AlgArgon2id, Salt: base64.StdEncoding.EncodeToString(salt),
		Time: 1, MemKiB: 8192, Par: 1, Len: 32,
	}
	sum := argon2.IDKey([]byte(code), salt, v.Time, v.MemKiB, v.Par, v.Len)
	v.Hash = base64.StdEncoding.EncodeToString(sum)
	return v
}

type harness struct {
	t     *testing.T
	hub   *Hub
	clock *clockx.Fake
	store *store.Store
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	clk := clockx.NewFake()
	h := New(Options{
		Store:      st,
		Clock:      clk,
		Signer:     auth.NewSigner([]byte("test-hmac-secret-0123456789abcdef")),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		TurnSecret: "turnsecret",
		TurnURLs:   []string{"turn:198.51.100.7:3478?transport=udp"},
		StunURLs:   []string{"stun:stun.example:3478"},
	})
	return &harness{t: t, hub: h, clock: clk, store: st}
}

// peer is a fake client connection driven directly against the hub.
type peer struct {
	t        *testing.T
	h        *Hub
	c        *Client
	priv     *ecdsa.PrivateKey
	pubB64   string
	deviceID string
	token    string
	session  string

	mu       sync.Mutex
	msgs     []protocol.Envelope
	nonce    string
	closed   bool
	closeMsg string
}

func (hn *harness) newPeer() *peer {
	hn.t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		hn.t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		hn.t.Fatal(err)
	}
	p := &peer{t: hn.t, h: hn.hub, priv: priv, pubB64: base64.StdEncoding.EncodeToString(spki)}
	p.c = hn.hub.AddClient(p.recv, func(code int, msg string) {
		p.mu.Lock()
		defer p.mu.Unlock()
		p.closed, p.closeMsg = true, msg
	})
	return p
}

// reconnect simulates the WebSocket dropping and a fresh socket being opened
// for the same device: new hub Client, same keypair, same recorded messages.
func (hn *harness) reconnect(p *peer) {
	hn.t.Helper()
	hn.hub.RemoveClient(p.c)
	p.mu.Lock()
	p.msgs = nil
	p.closed = false
	p.mu.Unlock()
	p.c = hn.hub.AddClient(p.recv, func(code int, msg string) {
		p.mu.Lock()
		defer p.mu.Unlock()
		p.closed, p.closeMsg = true, msg
	})
}

func (p *peer) recv(b []byte) {
	e, err := protocol.Decode(b)
	if err != nil {
		p.t.Errorf("server sent an undecodable frame: %v (%s)", err, string(b))
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.msgs = append(p.msgs, e)
	if e.Type == protocol.TypeChallenge {
		var ch protocol.Challenge
		if err := protocol.Unmarshal(e, &ch); err == nil {
			p.nonce = ch.Nonce
		}
	}
}

func (p *peer) send(typ string, payload any) {
	p.t.Helper()
	b, err := protocol.Encode(typ, "req", "", 0, payload)
	if err != nil {
		p.t.Fatal(err)
	}
	p.h.Handle(p.c, b)
}

// sig signs the current challenge nonce; tweak != nil mutates the nonce first
// so the test can forge a signature over the wrong bytes.
func (p *peer) sig(mangle bool) string {
	p.t.Helper()
	p.mu.Lock()
	nb, err := base64.StdEncoding.DecodeString(p.nonce)
	p.mu.Unlock()
	if err != nil {
		p.t.Fatalf("no challenge nonce: %v", err)
	}
	if mangle {
		nb[0] ^= 0xff
	}
	sum := sha256.Sum256(nb)
	sig, err := ecdsa.SignASN1(rand.Reader, p.priv, sum[:])
	if err != nil {
		p.t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

// sigOver signs an explicit base64 nonce, so tests can replay a stale one.
func (p *peer) sigOver(nonceB64 string) string {
	p.t.Helper()
	nb, err := base64.StdEncoding.DecodeString(nonceB64)
	if err != nil {
		p.t.Fatal(err)
	}
	sum := sha256.Sum256(nb)
	sig, err := ecdsa.SignASN1(rand.Reader, p.priv, sum[:])
	if err != nil {
		p.t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

// last returns the most recent message of the given type, or fails.
func (p *peer) last(typ string) protocol.Envelope {
	p.t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := len(p.msgs) - 1; i >= 0; i-- {
		if p.msgs[i].Type == typ {
			return p.msgs[i]
		}
	}
	p.t.Fatalf("no %q message received; got %s", typ, p.typesLocked())
	return protocol.Envelope{}
}

func (p *peer) has(typ string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, m := range p.msgs {
		if m.Type == typ {
			return true
		}
	}
	return false
}

func (p *peer) count(typ string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	n := 0
	for _, m := range p.msgs {
		if m.Type == typ {
			n++
		}
	}
	return n
}

func (p *peer) typesLocked() string {
	var ts []string
	for _, m := range p.msgs {
		ts = append(ts, m.Type)
	}
	return strings.Join(ts, ",")
}

func (p *peer) reset() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.msgs = nil
}

func (p *peer) lastErr() protocol.Error {
	p.t.Helper()
	var e protocol.Error
	if err := protocol.Unmarshal(p.last(protocol.TypeError), &e); err != nil {
		p.t.Fatal(err)
	}
	return e
}

func unmarshal[T any](t *testing.T, e protocol.Envelope) T {
	t.Helper()
	var v T
	if err := protocol.Unmarshal(e, &v); err != nil {
		t.Fatalf("decoding %s payload: %v", e.Type, err)
	}
	return v
}

// register + hello, the common setup.
func (p *peer) register(label string, v protocol.CodeVerifier) string {
	p.t.Helper()
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64, Sig: p.sig(false), Label: label, Code: v})
	ok := unmarshal[protocol.RegisterOK](p.t, p.last(protocol.TypeRegisterOK))
	p.deviceID = ok.DeviceID
	return ok.DeviceID
}

func (p *peer) hello(role string) protocol.HelloOK {
	p.t.Helper()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: p.deviceID, Pubkey: p.pubB64, Sig: p.sig(false), Role: role})
	return unmarshal[protocol.HelloOK](p.t, p.last(protocol.TypeHelloOK))
}

// ---------------------------------------------------------------------------
// registration + device authentication
// ---------------------------------------------------------------------------

func TestRegisterMintsNineDigitIDAndIsIdempotent(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("Studio Mac", fastVerifier(t, "ABCD2345"))

	if len(id) != 9 {
		t.Fatalf("deviceId %q: want 9 characters, got %d", id, len(id))
	}
	if !protocol.ValidDeviceID(id) {
		t.Fatalf("deviceId %q is not 9 digits", id)
	}
	if id[0] == '0' {
		t.Fatalf("deviceId %q must not start with 0", id)
	}
	first := unmarshal[protocol.RegisterOK](t, p.last(protocol.TypeRegisterOK))
	if first.Existing {
		t.Fatal("first registration reported existing=true")
	}

	// Same key again: same id, existing=true, and no second row.
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64, Sig: p.sig(false), Code: fastVerifier(t, "OTHERCODE")})
	second := unmarshal[protocol.RegisterOK](t, p.last(protocol.TypeRegisterOK))
	if second.DeviceID != id {
		t.Fatalf("re-registering the same key minted a new id: %q vs %q", second.DeviceID, id)
	}
	if !second.Existing {
		t.Fatal("re-registration reported existing=false")
	}

	// A different key gets a different id.
	q := hn.newPeer()
	id2 := q.register("Laptop", fastVerifier(t, "ZZZZ9999"))
	if id2 == id {
		t.Fatalf("two distinct keys got the same deviceId %q", id)
	}
}

func TestHelloValidSignatureAuthenticates(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("host", fastVerifier(t, "GOODCODE"))

	ok := p.hello(protocol.RoleHost)
	if ok.DeviceID != id {
		t.Fatalf("hello_ok.deviceId = %q, want %q", ok.DeviceID, id)
	}
	if ok.HeartbeatSec != 15 || ok.OfflineAfterSec != 40 || ok.SessionTokenTTLSec != 600 {
		t.Fatalf("hello_ok timings = %d/%d/%d, want 15/40/600",
			ok.HeartbeatSec, ok.OfflineAfterSec, ok.SessionTokenTTLSec)
	}
	if ok.ActiveSessionID != "" {
		t.Fatalf("hello_ok.activeSessionId = %q, want empty", ok.ActiveSessionID)
	}
	if !hn.hub.IsOnline(id) {
		t.Fatal("device should be online after hello")
	}
	// ICE servers: STUN first, then TURN with a deterministic REST credential.
	if len(ok.ICEServers) != 2 {
		t.Fatalf("iceServers len = %d, want 2", len(ok.ICEServers))
	}
	if ok.ICEServers[0].URLs[0] != "stun:stun.example:3478" || ok.ICEServers[0].Username != "" {
		t.Fatalf("first ICE server = %+v, want bare STUN", ok.ICEServers[0])
	}
	turn := ok.ICEServers[1]
	wantUser, wantCred, wantExp := auth.TurnCreds("turnsecret", id, hn.clock.Now(), TurnCredTTL)
	if turn.Username != wantUser || turn.Credential != wantCred {
		t.Fatalf("TURN creds = %q/%q, want %q/%q", turn.Username, turn.Credential, wantUser, wantCred)
	}
	if turn.ExpiresAt != wantExp.UnixMilli() {
		t.Fatalf("TURN expiry = %d, want %d", turn.ExpiresAt, wantExp.UnixMilli())
	}
	if !strings.HasSuffix(turn.Username, ":"+id) {
		t.Fatalf("TURN username %q must end in :%s", turn.Username, id)
	}
}

func TestHelloForgedSignatureRejected(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("host", fastVerifier(t, "GOODCODE"))

	// A signature over the wrong bytes.
	p.reset()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: p.pubB64, Sig: p.sig(true), Role: protocol.RoleHost})
	if p.has(protocol.TypeHelloOK) {
		t.Fatal("a forged signature was accepted")
	}
	if got := p.lastErr().Code; got != protocol.ErrBadSignature {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBadSignature)
	}
	if hn.hub.IsOnline(id) {
		t.Fatal("device must not be online after a failed hello")
	}

	// Another device's key, with a signature that is valid for that key.
	other := hn.newPeer()
	p.reset()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: other.pubB64, Sig: other.sig(false), Role: protocol.RoleHost})
	if p.has(protocol.TypeHelloOK) {
		t.Fatal("a signature from the wrong key was accepted")
	}
	if got := p.lastErr().Code; got != protocol.ErrBadSignature {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBadSignature)
	}

	// A nonce is single-use: a genuine signature over an already-consumed nonce
	// must still be rejected.
	q := hn.newPeer()
	q.deviceID, q.priv, q.pubB64 = id, p.priv, p.pubB64
	q.mu.Lock()
	firstNonce := q.nonce
	q.mu.Unlock()
	goodSig := q.sigOver(firstNonce)
	q.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: q.pubB64, Sig: "AAAA", Role: protocol.RoleHost}) // burns the nonce
	q.reset()
	q.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: q.pubB64, Sig: goodSig, Role: protocol.RoleHost})
	if q.has(protocol.TypeHelloOK) {
		t.Fatal("a signature over a consumed nonce was accepted")
	}
	if got := q.lastErr().Code; got != protocol.ErrBadSignature {
		t.Fatalf("replayed nonce error = %q, want %q", got, protocol.ErrBadSignature)
	}

	// And the fresh nonce from the re-challenge works.
	q.reset()
	q.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: q.pubB64, Sig: q.sig(false), Role: protocol.RoleHost})
	if !q.has(protocol.TypeHelloOK) {
		t.Fatalf("hello with the re-issued nonce failed: %s", q.typesLocked())
	}
}

func TestUnauthenticatedMessagesRejected(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	p.send(protocol.TypeWatch, protocol.Watch{DeviceID: "123456789"})
	if got := p.lastErr().Code; got != protocol.ErrUnauthenticated {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrUnauthenticated)
	}
	p.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	p.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if !closed {
		t.Fatal("connection should be closed after 3 unauthenticated messages")
	}
}

// ---------------------------------------------------------------------------
// access code
// ---------------------------------------------------------------------------

// pair registers a host and a controller and brings both online.
func (hn *harness) pair(t *testing.T, code string) (host, ctrl *peer) {
	t.Helper()
	host = hn.newPeer()
	host.register("host", fastVerifier(t, code))
	host.hello(protocol.RoleHost)
	ctrl = hn.newPeer()
	ctrl.register("ctrl", fastVerifier(t, "CTRLCODE"))
	ctrl.hello(protocol.RoleController)
	return host, ctrl
}

func TestConnectRightAndWrongCode(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")

	// Wrong code.
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9R"})
	if ctrl.has(protocol.TypeConnectOK) {
		t.Fatal("a wrong access code produced connect_ok")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadCode {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBadCode)
	}
	if host.has(protocol.TypeSessionStart) {
		t.Fatal("host was told about a session that was never created")
	}
	if n := hn.hub.FailCount(host.deviceID); n != 1 {
		t.Fatalf("fail count = %d, want 1", n)
	}

	// Right code.
	ctrl.reset()
	host.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	ok := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))
	if len(ok.SessionID) != 32 {
		t.Fatalf("sessionId %q: want 32 hex chars", ok.SessionID)
	}
	if ok.HostDeviceID != host.deviceID || ok.ControllerDeviceID != ctrl.deviceID {
		t.Fatalf("connect_ok participants = %q/%q, want %q/%q",
			ok.HostDeviceID, ok.ControllerDeviceID, host.deviceID, ctrl.deviceID)
	}
	if ok.TTLSec != 600 {
		t.Fatalf("ttlSec = %d, want 600", ok.TTLSec)
	}
	wantExp := hn.clock.Now().Add(SessionTokenTTL).UnixMilli()
	if ok.ExpiresAt != wantExp {
		t.Fatalf("expiresAt = %d, want %d", ok.ExpiresAt, wantExp)
	}
	if ok.SessionToken == "" {
		t.Fatal("connect_ok carried no session token")
	}
	start := unmarshal[protocol.SessionStart](t, host.last(protocol.TypeSessionStart))
	if start.SessionID != ok.SessionID {
		t.Fatalf("host sessionId = %q, controller = %q", start.SessionID, ok.SessionID)
	}
	if start.SessionToken == ok.SessionToken {
		t.Fatal("host and controller must not share a session token")
	}
	if got := hn.hub.SessionState(ok.SessionID); got != protocol.SessionOpen {
		t.Fatalf("session state = %q, want %q", got, protocol.SessionOpen)
	}
	// A success clears the earlier failure.
	if n := hn.hub.FailCount(host.deviceID); n != 0 {
		t.Fatalf("fail count after success = %d, want 0", n)
	}
}

func TestConnectOfflineAndUnknownDevice(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")

	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: "999999999", AccessCode: "x"})
	if got := ctrl.lastErr().Code; got != protocol.ErrUnknownDevice {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrUnknownDevice)
	}

	hn.hub.RemoveClient(host.c)
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if got := ctrl.lastErr().Code; got != protocol.ErrOffline {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrOffline)
	}
	// An offline rejection must not burn a rate-limit attempt.
	if n := hn.hub.FailCount(host.deviceID); n != 0 {
		t.Fatalf("fail count = %d, want 0 (offline is not a code failure)", n)
	}
}

// ---------------------------------------------------------------------------
// rate limiting
// ---------------------------------------------------------------------------

func TestRateLimitKicksInOnSixthFailure(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")

	for i := 1; i <= 5; i++ {
		ctrl.reset()
		ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "WRONG"})
		if got := ctrl.lastErr().Code; got != protocol.ErrBadCode {
			t.Fatalf("attempt %d: error code = %q, want %q", i, got, protocol.ErrBadCode)
		}
		if n := hn.hub.FailCount(host.deviceID); n != i {
			t.Fatalf("attempt %d: fail count = %d, want %d", i, n, i)
		}
		hn.clock.Advance(time.Second)
	}

	// 6th attempt is locked out, even though the code is wrong for a different reason.
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "WRONG"})
	e := ctrl.lastErr()
	if e.Code != protocol.ErrRateLimited {
		t.Fatalf("6th attempt: error code = %q, want %q", e.Code, protocol.ErrRateLimited)
	}
	if e.RetryAfterSec <= 0 || e.RetryAfterSec > 60 {
		t.Fatalf("retryAfterSec = %d, want 1..60 (first lockout is 1 minute)", e.RetryAfterSec)
	}

	// The CORRECT code is also refused while locked out.
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if ctrl.has(protocol.TypeConnectOK) {
		t.Fatal("lockout must refuse even the correct code")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrRateLimited {
		t.Fatalf("locked-out correct code: error code = %q, want %q", got, protocol.ErrRateLimited)
	}
	// A locked-out attempt does not count as a new failure.
	if n := hn.hub.FailCount(host.deviceID); n != 5 {
		t.Fatalf("fail count during lockout = %d, want 5", n)
	}

	// After the 1-minute lockout the correct code works again.
	hn.clock.Advance(61 * time.Second)
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if !ctrl.has(protocol.TypeConnectOK) {
		t.Fatalf("connect after lockout expiry failed: %s", ctrl.typesLocked())
	}
}

func TestRateLimitLockoutIsExponential(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")

	fail := func() protocol.Error {
		ctrl.reset()
		ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "WRONG"})
		return ctrl.lastErr()
	}
	for i := 0; i < 5; i++ {
		if got := fail().Code; got != protocol.ErrBadCode {
			t.Fatalf("attempt %d should be bad_code, got %s", i+1, got)
		}
	}
	// Lockouts double: 60s, then 120s, then 240s.
	for i, want := range []int{60, 120, 240} {
		if got := fail(); got.Code != protocol.ErrRateLimited || got.RetryAfterSec != want {
			t.Fatalf("lockout %d: code=%s retryAfterSec=%d, want rate_limited/%d",
				i+1, got.Code, got.RetryAfterSec, want)
		}
		hn.clock.Advance(time.Duration(want) * time.Second)
		// One more failure past the expired lockout deepens it.
		if got := fail().Code; got != protocol.ErrBadCode {
			t.Fatalf("after lockout %d expired, expected bad_code, got %s", i+1, got)
		}
	}
}

func TestRateLimitWindowDecays(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")
	for i := 0; i < 4; i++ {
		ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "WRONG"})
	}
	if n := hn.hub.FailCount(host.deviceID); n != 4 {
		t.Fatalf("fail count = %d, want 4", n)
	}
	hn.clock.Advance(FailWindow + time.Second)
	if n := hn.hub.FailCount(host.deviceID); n != 0 {
		t.Fatalf("fail count after the window elapsed = %d, want 0", n)
	}
}

// ---------------------------------------------------------------------------
// strict 1:1
// ---------------------------------------------------------------------------

func TestSecondControllerGetsBusy(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	first := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))

	second := hn.newPeer()
	second.register("ctrl2", fastVerifier(t, "OTHER"))
	second.hello(protocol.RoleController)
	second.reset()
	second.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})

	if second.has(protocol.TypeConnectOK) {
		t.Fatal("a second controller was allowed into an active session")
	}
	if got := second.lastErr().Code; got != protocol.ErrBusy {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBusy)
	}
	if got := hn.hub.SessionState(first.SessionID); got != protocol.SessionOpen {
		t.Fatalf("original session state = %q, want open", got)
	}

	// The slot is still held while the session is merely half_open.
	hn.hub.RemoveClient(ctrl.c)
	if got := hn.hub.SessionState(first.SessionID); got != protocol.SessionHalfOpen {
		t.Fatalf("session state after controller drop = %q, want half_open", got)
	}
	second.reset()
	second.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if got := second.lastErr().Code; got != protocol.ErrBusy {
		t.Fatalf("half_open session: error code = %q, want busy", got)
	}

	// Once the first session is closed the slot frees.
	host.send(protocol.TypeBye, protocol.Bye{SessionID: first.SessionID, Reason: protocol.ByeHostEnded})
	if got := hn.hub.SessionState(first.SessionID); got != "" {
		t.Fatalf("session should be gone after bye, state = %q", got)
	}
	second.reset()
	second.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if !second.has(protocol.TypeConnectOK) {
		t.Fatalf("second controller should connect after bye; got %s", second.typesLocked())
	}
}

func TestSelfConnectRejected(t *testing.T) {
	hn := newHarness(t)
	host, _ := hn.pair(t, "SW7K2M9Q")
	host.reset()
	host.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if got := host.lastErr().Code; got != protocol.ErrSelfConnect {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrSelfConnect)
	}
}

// ---------------------------------------------------------------------------
// presence
// ---------------------------------------------------------------------------

func TestPresenceGoesOfflineAfterTimeout(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")

	ctrl.reset()
	ctrl.send(protocol.TypeWatch, protocol.Watch{DeviceID: host.deviceID})
	if got := unmarshal[protocol.WatchOK](t, ctrl.last(protocol.TypeWatchOK)).DeviceID; got != host.deviceID {
		t.Fatalf("watch_ok.deviceId = %q, want %q", got, host.deviceID)
	}
	p := unmarshal[protocol.Presence](t, ctrl.last(protocol.TypePresence))
	if !p.Online {
		t.Fatal("initial presence should be online")
	}
	if p.Since != hn.clock.Now().UnixMilli() {
		t.Fatalf("presence.since = %d, want %d", p.Since, hn.clock.Now().UnixMilli())
	}
	if n := ctrl.count(protocol.TypePresence); n != 1 {
		t.Fatalf("presence pushes = %d, want 1", n)
	}

	// 39s of silence: still online, no new push.
	hn.clock.Advance(39 * time.Second)
	hn.hub.Sweep()
	if !hn.hub.IsOnline(host.deviceID) {
		t.Fatal("device went offline before the 40s threshold")
	}
	if n := ctrl.count(protocol.TypePresence); n != 1 {
		t.Fatalf("presence pushes after 39s = %d, want 1", n)
	}

	// Cross 40s: offline, exactly one new push.
	hn.clock.Advance(2 * time.Second)
	offlineAt := hn.clock.Now()
	hn.hub.Sweep()
	if hn.hub.IsOnline(host.deviceID) {
		t.Fatal("device should be offline after 41s of silence")
	}
	if n := ctrl.count(protocol.TypePresence); n != 2 {
		t.Fatalf("presence pushes after 41s = %d, want 2", n)
	}
	off := unmarshal[protocol.Presence](t, ctrl.last(protocol.TypePresence))
	if off.Online {
		t.Fatal("pushed presence should be online=false")
	}
	if off.DeviceID != host.deviceID {
		t.Fatalf("presence.deviceId = %q, want %q", off.DeviceID, host.deviceID)
	}
	if off.Since != offlineAt.UnixMilli() {
		t.Fatalf("presence.since = %d, want %d", off.Since, offlineAt.UnixMilli())
	}

	// A heartbeat brings it back, with one more push.
	host.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	if !hn.hub.IsOnline(host.deviceID) {
		t.Fatal("a heartbeat should bring the device back online")
	}
	if n := ctrl.count(protocol.TypePresence); n != 3 {
		t.Fatalf("presence pushes after heartbeat = %d, want 3", n)
	}
	back := unmarshal[protocol.Presence](t, ctrl.last(protocol.TypePresence))
	if !back.Online {
		t.Fatal("presence should be online again")
	}
	// Repeated heartbeats do not spam watchers.
	host.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	if n := ctrl.count(protocol.TypePresence); n != 3 {
		t.Fatalf("presence pushes after a second heartbeat = %d, want 3", n)
	}
}

func TestPresenceOfflineImmediatelyOnDisconnect(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")
	ctrl.send(protocol.TypeWatch, protocol.Watch{DeviceID: host.deviceID})
	ctrl.reset()
	hn.hub.RemoveClient(host.c)
	if hn.hub.IsOnline(host.deviceID) {
		t.Fatal("a closed socket should be offline immediately, not after 40s")
	}
	p := unmarshal[protocol.Presence](t, ctrl.last(protocol.TypePresence))
	if p.Online || p.DeviceID != host.deviceID {
		t.Fatalf("presence push = %+v, want offline for %s", p, host.deviceID)
	}
}

func TestUnwatchStopsPushes(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t, "SW7K2M9Q")
	ctrl.send(protocol.TypeWatch, protocol.Watch{DeviceID: host.deviceID})
	ctrl.send(protocol.TypeUnwatch, protocol.Unwatch{DeviceID: host.deviceID})
	ctrl.reset()
	hn.hub.RemoveClient(host.c)
	if ctrl.has(protocol.TypePresence) {
		t.Fatal("presence was pushed after unwatch")
	}
}

// ---------------------------------------------------------------------------
// resume
// ---------------------------------------------------------------------------

// openSession brings up a host+controller session and returns both tokens.
func (hn *harness) openSession(t *testing.T, code string) (host, ctrl *peer, sessionID, hostTok, ctrlTok string) {
	t.Helper()
	host, ctrl = hn.pair(t, code)
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: code})
	ok := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))
	st := unmarshal[protocol.SessionStart](t, host.last(protocol.TypeSessionStart))
	return host, ctrl, ok.SessionID, st.SessionToken, ok.SessionToken
}

func TestResumeWithValidTokenSurvivesSocketDrop(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, ctrlTok := hn.openSession(t, "SW7K2M9Q")

	// The controller's socket dies. The session must NOT.
	host.reset()
	hn.hub.RemoveClient(ctrl.c)
	if got := hn.hub.SessionState(sid); got != protocol.SessionHalfOpen {
		t.Fatalf("session state after drop = %q, want half_open", got)
	}
	ps := unmarshal[protocol.PeerState](t, host.last(protocol.TypePeerState))
	if ps.Attached || ps.SessionID != sid {
		t.Fatalf("host peer_state = %+v, want detached for %s", ps, sid)
	}

	// Two minutes of network flutter, then a fresh socket, re-auth and resume —
	// with no access code anywhere in the path.
	hn.clock.Advance(2 * time.Minute)
	hn.reconnect(ctrl)
	helloOK := ctrl.hello(protocol.RoleController)
	if helloOK.ActiveSessionID != sid {
		t.Fatalf("hello_ok.activeSessionId = %q, want %q", helloOK.ActiveSessionID, sid)
	}
	host.reset()
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	r := unmarshal[protocol.ResumeOK](t, ctrl.last(protocol.TypeResumeOK))
	if r.SessionID != sid {
		t.Fatalf("resume_ok.sessionId = %q, want %q", r.SessionID, sid)
	}
	if r.SessionToken == ctrlTok {
		t.Fatal("resume must rotate the session token")
	}
	if !r.PeerAttached {
		t.Fatal("resume_ok.peerAttached = false, but the host is still connected")
	}
	if r.Role != protocol.RoleController {
		t.Fatalf("resume_ok.role = %q, want controller", r.Role)
	}
	if r.ExpiresAt != hn.clock.Now().Add(SessionTokenTTL).UnixMilli() {
		t.Fatalf("resume_ok.expiresAt = %d, want %d", r.ExpiresAt,
			hn.clock.Now().Add(SessionTokenTTL).UnixMilli())
	}
	if got := hn.hub.SessionState(sid); got != protocol.SessionOpen {
		t.Fatalf("session state after resume = %q, want open", got)
	}
	if ps := unmarshal[protocol.PeerState](t, host.last(protocol.TypePeerState)); !ps.Attached {
		t.Fatal("host should have been told the peer re-attached")
	}

	// The old token is dead now that it has been rotated away.
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	if ctrl.has(protocol.TypeResumeOK) {
		t.Fatal("a rotated-away token was accepted")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("stale token error = %q, want %q", got, protocol.ErrBadToken)
	}
	// ...but the rotated one still works.
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: r.SessionToken})
	if !ctrl.has(protocol.TypeResumeOK) {
		t.Fatalf("the rotated token should still resume; got %s", ctrl.typesLocked())
	}
}

func TestResumeWithForgedOrExpiredTokenFails(t *testing.T) {
	hn := newHarness(t)
	_, ctrl, sid, _, ctrlTok := hn.openSession(t, "SW7K2M9Q")
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)

	// Forged: flip a byte of the MAC.
	forged := []byte(ctrlTok)
	forged[len(forged)-1] ^= 0x01
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: string(forged)})
	if ctrl.has(protocol.TypeResumeOK) {
		t.Fatal("a token with a tampered MAC was accepted")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("forged token error = %q, want %q", got, protocol.ErrBadToken)
	}

	// Garbage.
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: "not-a-token"})
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("garbage token error = %q, want %q", got, protocol.ErrBadToken)
	}

	// A token minted by a different server secret must not verify.
	other := auth.NewSigner([]byte("a completely different hmac secret!!"))
	alien := other.Mint(auth.TokenClaims{SessionID: sid, DeviceID: ctrl.deviceID,
		Expiry: hn.clock.Now().Add(time.Hour), Epoch: 1, Nonce: "whatever"})
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: alien})
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("alien token error = %q, want %q", got, protocol.ErrBadToken)
	}

	// Expired: past the 10-minute TTL the session is swept away entirely.
	hn.clock.Advance(SessionTokenTTL + time.Second)
	hn.hub.Sweep()
	if got := hn.hub.SessionState(sid); got != "" {
		t.Fatalf("session should have expired, state = %q", got)
	}
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("expired session error = %q, want %q", got, protocol.ErrNoSession)
	}
}

func TestResumeRejectsAnotherDevicesToken(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, hostTok, _ := hn.openSession(t, "SW7K2M9Q")
	_ = host
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	// The controller presents the HOST's token.
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: hostTok})
	if ctrl.has(protocol.TypeResumeOK) {
		t.Fatal("a token bound to the other device was accepted")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("error = %q, want %q", got, protocol.ErrBadToken)
	}
}

func TestOrphanedSessionSurvivesUntilTokenExpiry(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, hostTok, ctrlTok := hn.openSession(t, "SW7K2M9Q")

	hn.hub.RemoveClient(host.c)
	hn.hub.RemoveClient(ctrl.c)
	if got := hn.hub.SessionState(sid); got != protocol.SessionOrphaned {
		t.Fatalf("session state with both sides gone = %q, want orphaned", got)
	}
	hn.clock.Advance(9 * time.Minute)
	hn.hub.Sweep()
	if got := hn.hub.SessionState(sid); got != protocol.SessionOrphaned {
		t.Fatalf("session died at 9 minutes, before the 10-minute token TTL: %q", got)
	}
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	r := unmarshal[protocol.ResumeOK](t, ctrl.last(protocol.TypeResumeOK))
	if r.PeerAttached {
		t.Fatal("peerAttached should be false while the host is still away")
	}
	if got := hn.hub.SessionState(sid); got != protocol.SessionHalfOpen {
		t.Fatalf("state after one side resumed = %q, want half_open", got)
	}
	// The host's token is now the only thing keeping the other side resumable.
	hn.reconnect(host)
	host.hello(protocol.RoleHost)
	host.reset()
	host.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: hostTok})
	if !host.has(protocol.TypeResumeOK) {
		t.Fatalf("host resume failed: %s", host.typesLocked())
	}
	if got := hn.hub.SessionState(sid); got != protocol.SessionOpen {
		t.Fatalf("state after both resumed = %q, want open", got)
	}
}

func TestRenewExtendsTheResumeWindow(t *testing.T) {
	hn := newHarness(t)
	_, ctrl, sid, _, ctrlTok := hn.openSession(t, "SW7K2M9Q")

	hn.clock.Advance(5 * time.Minute)
	ctrl.reset()
	ctrl.send(protocol.TypeRenew, protocol.Renew{SessionID: sid, SessionToken: ctrlTok})
	r := unmarshal[protocol.RenewOK](t, ctrl.last(protocol.TypeRenewOK))
	if r.SessionToken == ctrlTok {
		t.Fatal("renew must rotate the token")
	}
	if r.ExpiresAt != hn.clock.Now().Add(SessionTokenTTL).UnixMilli() {
		t.Fatalf("renew_ok.expiresAt = %d, want %d", r.ExpiresAt,
			hn.clock.Now().Add(SessionTokenTTL).UnixMilli())
	}
	// 8 more minutes: the ORIGINAL token would have expired; the renewed one has not.
	hn.clock.Advance(8 * time.Minute)
	hn.reconnect(ctrl)
	hn.hub.Sweep()
	if got := hn.hub.SessionState(sid); got != protocol.SessionHalfOpen {
		t.Fatalf("session state = %q, want half_open (renew should have kept it alive)", got)
	}
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: r.SessionToken})
	if !ctrl.has(protocol.TypeResumeOK) {
		t.Fatalf("resume with the renewed token failed: %s", ctrl.typesLocked())
	}
}

// ---------------------------------------------------------------------------
// relay
// ---------------------------------------------------------------------------

func TestSDPAndICERelayVerbatim(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t, "SW7K2M9Q")

	const body = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=-\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
	host.reset()
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: body})
	got := unmarshal[protocol.SDP](t, host.last(protocol.TypeSDP))
	if got.SDP != body {
		t.Fatalf("relayed SDP was altered:\n got %q\nwant %q", got.SDP, body)
	}
	if got.SDPType != "offer" || got.SessionID != sid {
		t.Fatalf("relayed SDP metadata = %+v", got)
	}

	ctrl.reset()
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "answer", SDP: body + "a=recvonly\r\n"})
	ans := unmarshal[protocol.SDP](t, ctrl.last(protocol.TypeSDP))
	if ans.SDPType != "answer" || !strings.HasSuffix(ans.SDP, "a=recvonly\r\n") {
		t.Fatalf("answer relay wrong: %+v", ans)
	}

	host.reset()
	cand := "candidate:1 1 udp 2113937151 192.0.2.1 54321 typ host"
	ctrl.send(protocol.TypeICE, protocol.ICE{SessionID: sid, Candidate: cand, SDPMid: "0", SDPMLineIndex: 0})
	ice := unmarshal[protocol.ICE](t, host.last(protocol.TypeICE))
	if ice.Candidate != cand || ice.SDPMid != "0" {
		t.Fatalf("relayed ICE = %+v, want candidate %q", ice, cand)
	}

	// Wrong session id is refused.
	ctrl.reset()
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: "00000000000000000000000000000000", SDPType: "offer", SDP: body})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("relay to an unknown session: error = %q, want %q", got, protocol.ErrNoSession)
	}

	// With the peer detached, relay is refused rather than queued.
	hn.reconnect(host)
	ctrl.reset()
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: body})
	if got := ctrl.lastErr().Code; got != protocol.ErrPeerOffline {
		t.Fatalf("relay with peer detached: error = %q, want %q", got, protocol.ErrPeerOffline)
	}
}

func TestByeClosesSessionForBothSides(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, ctrlTok := hn.openSession(t, "SW7K2M9Q")
	host.reset()
	ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: sid, Reason: protocol.ByeUserEnded})
	b := unmarshal[protocol.Bye](t, host.last(protocol.TypeBye))
	if b.SessionID != sid || b.Reason != protocol.ByeUserEnded {
		t.Fatalf("relayed bye = %+v", b)
	}
	if got := hn.hub.SessionState(sid); got != "" {
		t.Fatalf("session state after bye = %q, want gone", got)
	}
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("resume after bye: error = %q, want %q", got, protocol.ErrNoSession)
	}
}

// ---------------------------------------------------------------------------
// access-code refresh
// ---------------------------------------------------------------------------

func TestRefreshInvalidatesOldCodeAndSessions(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, ctrlTok := hn.openSession(t, "SW7K2M9Q")

	before, err := hn.store.GetDevice(host.deviceID)
	if err != nil {
		t.Fatal(err)
	}

	ctrl.reset()
	host.reset()
	hn.clock.Advance(time.Minute)
	host.send(protocol.TypeRefreshCode, fastVerifier(t, "NEWCODE1"))
	ok := unmarshal[protocol.RefreshCodeOK](t, host.last(protocol.TypeRefreshCodeOK))
	if ok.DeviceID != host.deviceID {
		t.Fatalf("refresh_code_ok.deviceId = %q, want %q", ok.DeviceID, host.deviceID)
	}
	if ok.UpdatedAt != hn.clock.Now().UnixMilli() {
		t.Fatalf("refresh_code_ok.updatedAt = %d, want %d", ok.UpdatedAt, hn.clock.Now().UnixMilli())
	}

	// The stored verifier really changed and the epoch advanced.
	after, err := hn.store.GetDevice(host.deviceID)
	if err != nil {
		t.Fatal(err)
	}
	if after.Code.Hash == before.Code.Hash || after.Code.Salt == before.Code.Salt {
		t.Fatal("the stored verifier was not replaced")
	}
	if after.CodeEpoch != before.CodeEpoch+1 {
		t.Fatalf("code epoch = %d, want %d", after.CodeEpoch, before.CodeEpoch+1)
	}

	// The live session was killed, both sides told why.
	if got := hn.hub.SessionState(sid); got != "" {
		t.Fatalf("session state after refresh = %q, want gone", got)
	}
	b := unmarshal[protocol.Bye](t, ctrl.last(protocol.TypeBye))
	if b.Reason != protocol.ByeCodeRefreshed || b.SessionID != sid {
		t.Fatalf("controller bye = %+v, want code_refreshed for %s", b, sid)
	}

	// The token from before the refresh no longer resumes.
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("resume after refresh: error = %q, want %q", got, protocol.ErrNoSession)
	}

	// The OLD access code is rejected, the NEW one works.
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if ctrl.has(protocol.TypeConnectOK) {
		t.Fatal("the old access code still works after a refresh")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadCode {
		t.Fatalf("old code error = %q, want %q", got, protocol.ErrBadCode)
	}
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID, AccessCode: "NEWCODE1"})
	if !ctrl.has(protocol.TypeConnectOK) {
		t.Fatalf("the new access code was rejected: %s", ctrl.typesLocked())
	}
}

func TestRefreshRejectsBadParameters(t *testing.T) {
	hn := newHarness(t)
	host, _ := hn.pair(t, "SW7K2M9Q")
	before, _ := hn.store.GetDevice(host.deviceID)

	bad := fastVerifier(t, "X")
	bad.MemKiB = 1024 // below the permitted floor
	host.reset()
	host.send(protocol.TypeRefreshCode, bad)
	if host.has(protocol.TypeRefreshCodeOK) {
		t.Fatal("an out-of-range Argon2 parameter was accepted")
	}
	if got := host.lastErr().Code; got != protocol.ErrBadRequest {
		t.Fatalf("error = %q, want %q", got, protocol.ErrBadRequest)
	}
	after, _ := hn.store.GetDevice(host.deviceID)
	if after.Code.Hash != before.Code.Hash {
		t.Fatal("a rejected refresh still modified the stored verifier")
	}
}

// ---------------------------------------------------------------------------
// misc
// ---------------------------------------------------------------------------

func TestUnsupportedVersionClosesConnection(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	raw, _ := json.Marshal(map[string]any{"v": 99, "type": "hello", "payload": map[string]any{}})
	hn.hub.Handle(p.c, raw)
	if got := p.lastErr().Code; got != protocol.ErrUnsupportedVersion {
		t.Fatalf("error = %q, want %q", got, protocol.ErrUnsupportedVersion)
	}
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if !closed {
		t.Fatal("a bad protocol version should close the connection")
	}
}

func TestSecondHelloDisplacesFirstConnection(t *testing.T) {
	hn := newHarness(t)
	first := hn.newPeer()
	id := first.register("host", fastVerifier(t, "SW7K2M9Q"))
	first.hello(protocol.RoleHost)

	second := hn.newPeer()
	second.deviceID, second.priv, second.pubB64 = id, first.priv, first.pubB64
	first.reset()
	second.hello(protocol.RoleHost)

	if got := first.lastErr().Code; got != protocol.ErrDisplaced {
		t.Fatalf("first connection error = %q, want %q", got, protocol.ErrDisplaced)
	}
	first.mu.Lock()
	closed := first.closed
	first.mu.Unlock()
	if !closed {
		t.Fatal("the displaced connection should be closed")
	}
	if !hn.hub.IsOnline(id) {
		t.Fatal("the device should still be online via the new connection")
	}
}

func TestShutdownClosesSessions(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t, "SW7K2M9Q")
	host.reset()
	ctrl.reset()
	hn.hub.Shutdown()
	if got := hn.hub.SessionState(sid); got != "" {
		t.Fatalf("session state after shutdown = %q, want gone", got)
	}
	for _, p := range []*peer{host, ctrl} {
		b := unmarshal[protocol.Bye](t, p.last(protocol.TypeBye))
		if b.Reason != protocol.ByeShutdown {
			t.Fatalf("bye reason = %q, want %q", b.Reason, protocol.ByeShutdown)
		}
	}
}
