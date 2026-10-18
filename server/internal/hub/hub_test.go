package hub

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/clockx"
	"rc-signal/internal/entitlement"
	"rc-signal/internal/idcert"
	"rc-signal/internal/registry"
	"rc-signal/internal/reports"
	"rc-signal/internal/store"
	"rcprotocol"
)

type fakeEntitlement struct {
	mu        sync.Mutex
	deny      map[string]string
	err       error
	pairErr   error
	denyStart bool
	startErr  error
	pairs     map[string]bool
	pairAsks  int
	starts    []protocol.SessionStartReport
	stops     []protocol.SessionStopReport
	order     []string
}

func newFakeEntitlement() *fakeEntitlement {
	return &fakeEntitlement{deny: map[string]string{}, pairs: map[string]bool{}}
}

func (f *fakeEntitlement) KnownPair(_ context.Context, hostDeviceID, controllerDeviceID string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pairAsks++
	return f.pairs[pairKey(hostDeviceID, controllerDeviceID)], f.pairErr
}

func (f *fakeEntitlement) knowPair(hostDeviceID, controllerDeviceID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pairs[pairKey(hostDeviceID, controllerDeviceID)] = true
}

func (f *fakeEntitlement) Check(_ context.Context, hostDeviceID string) (entitlement.Decision, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return entitlement.Decision{}, f.err
	}
	if reason, denied := f.deny[hostDeviceID]; denied {
		return entitlement.Denied(reason), nil
	}
	return entitlement.Allowed, nil
}

func (f *fakeEntitlement) SessionStarted(_ context.Context, r protocol.SessionStartReport) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.startErr != nil {
		return f.startErr
	}
	if f.denyStart {
		return reports.ErrDenied
	}
	f.starts = append(f.starts, r)
	f.pairs[pairKey(r.HostDeviceID, r.ControllerDeviceID)] = true
	f.order = append(f.order, "start "+r.SessionID)
	return nil
}

func (f *fakeEntitlement) SessionStopped(_ context.Context, r protocol.SessionStopReport) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stops = append(f.stops, r)
	f.order = append(f.order, "stop "+r.SessionID)
	return nil
}

func (f *fakeEntitlement) reportCounts() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.starts), len(f.stops)
}

func (f *fakeEntitlement) denyDevice(deviceID, reason string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deny[deviceID] = reason
}

func (f *fakeEntitlement) allowDevice(deviceID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.deny, deviceID)
}

func (f *fakeEntitlement) failWith(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *fakeEntitlement) awaitReports(t *testing.T, starts, stops int) ([]protocol.SessionStartReport, []protocol.SessionStopReport) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		f.mu.Lock()
		gotStarts := append([]protocol.SessionStartReport(nil), f.starts...)
		gotStops := append([]protocol.SessionStopReport(nil), f.stops...)
		f.mu.Unlock()
		if len(gotStarts) >= starts && len(gotStops) >= stops {
			return gotStarts, gotStops
		}
		if time.Now().After(deadline) {
			t.Fatalf("reports = %d start / %d stop, want %d / %d",
				len(gotStarts), len(gotStops), starts, stops)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

type switchableRegistry struct {
	mu        sync.Mutex
	backend   registry.Registry
	down      bool
	gate      chan struct{}
	certifies int
}

func (r *switchableRegistry) inner() registry.Registry {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.backend
}

func (r *switchableRegistry) replace(backend registry.Registry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.backend = backend
}

func (r *switchableRegistry) setDown(down bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.down = down
}

func (r *switchableRegistry) holdLookups() func() {
	gate := make(chan struct{})
	r.mu.Lock()
	r.gate = gate
	r.mu.Unlock()
	return func() {
		r.mu.Lock()
		r.gate = nil
		r.mu.Unlock()
		close(gate)
	}
}

func (r *switchableRegistry) state() (bool, chan struct{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.down, r.gate
}

func (r *switchableRegistry) Register(ctx context.Context, reg registry.Registration) (registry.Registered, error) {
	if down, _ := r.state(); down {
		return registry.Registered{}, registry.ErrUnavailable
	}
	return r.inner().Register(ctx, reg)
}

func (r *switchableRegistry) Lookup(ctx context.Context, deviceID string) (registry.Device, error) {
	down, gate := r.state()
	if gate != nil {
		<-gate
	}
	if down {
		return registry.Device{}, registry.ErrUnavailable
	}
	return r.inner().Lookup(ctx, deviceID)
}

func (r *switchableRegistry) Certify(ctx context.Context, deviceID, pubkey string) (registry.Device, error) {
	r.mu.Lock()
	r.certifies++
	r.mu.Unlock()
	down, gate := r.state()
	if gate != nil {
		<-gate
	}
	if down {
		return registry.Device{}, registry.ErrUnavailable
	}
	return r.inner().Certify(ctx, deviceID, pubkey)
}

func (r *switchableRegistry) BumpEpoch(ctx context.Context, deviceID string) error {
	if down, _ := r.state(); down {
		return registry.ErrUnavailable
	}
	return r.inner().BumpEpoch(ctx, deviceID)
}

type harness struct {
	t         *testing.T
	hub       *Hub
	clock     *clockx.Fake
	store     *store.Store
	claims    string
	reg       *switchableRegistry
	ent       *fakeEntitlement
	authority *idcert.Authority
	pool      []*peer
}

const peerIP = "192.0.2.10"

func newHarness(t *testing.T) *harness {
	t.Helper()
	claims := filepath.Join(t.TempDir(), "claims.db")
	st, err := store.Open(":memory:", claims)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	authority, err := idcert.Ephemeral()
	if err != nil {
		t.Fatal(err)
	}
	clk := clockx.NewFake()
	ent := newFakeEntitlement()
	reg := &switchableRegistry{backend: registry.NewLocal(st, clk, authority)}
	h := New(Options{
		Registry:    reg,
		Entitlement: ent,
		Clock:       clk,
		Signer:      auth.NewSigner([]byte("test-hmac-secret-0123456789abcdef")),
		Logger:      slog.New(slog.NewTextHandler(io.Discard, nil)),
		TurnSecret:  "turnsecret",
		TurnURLs:    []string{"turn:198.51.100.7:3478?transport=udp"},
		StunURLs:    []string{"stun:stun.example:3478"},
		Reports:     reports.Options{Backoff: time.Millisecond, MaxBackoff: 2 * time.Millisecond},
	})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		h.FlushReports(ctx)
	})
	return &harness{t: t, hub: h, clock: clk, store: st, claims: claims, reg: reg, ent: ent, authority: authority}
}

type peer struct {
	t        *testing.T
	h        *Hub
	c        *Client
	ip       string
	priv     *ecdsa.PrivateKey
	pubB64   string
	deviceID string
	idCert   string
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
	return hn.newPeerAt(peerIP)
}

func (hn *harness) newPeerAt(ip string) *peer {
	hn.t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		hn.t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		hn.t.Fatal(err)
	}
	p := &peer{t: hn.t, h: hn.hub, ip: ip, priv: priv, pubB64: base64.StdEncoding.EncodeToString(spki)}
	p.c = hn.hub.AddClient(ip, p.recv, func(code int, msg string) {
		p.mu.Lock()
		defer p.mu.Unlock()
		p.closed, p.closeMsg = true, msg
	})
	return p
}

// The same device on a brand-new socket, as a process that was killed and started again: same
// key and id, nothing in memory.
func (hn *harness) restarted(old *peer) *peer {
	hn.t.Helper()
	p := &peer{t: hn.t, h: hn.hub, ip: old.ip, priv: old.priv, pubB64: old.pubB64,
		deviceID: old.deviceID, idCert: old.idCert}
	p.c = hn.hub.AddClient(p.ip, p.recv, func(code int, msg string) {
		p.mu.Lock()
		defer p.mu.Unlock()
		p.closed, p.closeMsg = true, msg
	})
	return p
}

func TestARestartedControllerReplacesItsOwnDetachedSession(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	first := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))

	hn.hub.RemoveClient(ctrl.c)
	if got := hn.hub.SessionState(first.SessionID); got != protocol.SessionHalfOpen {
		t.Fatalf("session state after the controller died = %q, want half_open", got)
	}

	again := hn.restarted(ctrl)
	again.hello(protocol.RoleController)
	host.reset()
	again.reset()
	again.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})

	second := unmarshal[protocol.ConnectOK](t, again.last(protocol.TypeConnectOK))
	if second.SessionID == first.SessionID {
		t.Fatal("the dead session was handed back instead of a fresh one")
	}
	if got := hn.hub.SessionState(first.SessionID); got != "" && got != protocol.SessionClosed {
		t.Fatalf("dead session state = %q, want closed and gone", got)
	}
	bye := unmarshal[protocol.Bye](t, host.last(protocol.TypeBye))
	if bye.SessionID != first.SessionID || bye.Reason != protocol.ByeReplaced {
		t.Fatalf("host bye = %+v, want %s for the dead session", bye, protocol.ByeReplaced)
	}
	if !host.has(protocol.TypeSessionStart) {
		t.Fatal("host never received session_start for the fresh session")
	}
}

func TestAnAttachedControllerIsNotDisplacedByConnectReq(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	first := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))

	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if got := ctrl.lastErr().Code; got != protocol.ErrBusy {
		t.Fatalf("a live controller re-sending connect_req got %q, want busy", got)
	}
	if got := hn.hub.SessionState(first.SessionID); got != protocol.SessionOpen {
		t.Fatalf("live session state = %q, want open", got)
	}
}

func (hn *harness) reconnect(p *peer) {
	hn.t.Helper()
	hn.hub.RemoveClient(p.c)
	p.mu.Lock()
	p.msgs = nil
	p.closed = false
	p.mu.Unlock()
	p.c = hn.hub.AddClient(p.ip, p.recv, func(code int, msg string) {
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

func (p *peer) sig(purpose protocol.SigningPurpose, mangle bool) string {
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
	return p.signNonce(purpose, nb)
}

func (p *peer) currentNonce() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.nonce
}

func (p *peer) sigOver(purpose protocol.SigningPurpose, nonceB64 string) string {
	p.t.Helper()
	nb, err := base64.StdEncoding.DecodeString(nonceB64)
	if err != nil {
		p.t.Fatal(err)
	}
	return p.signNonce(purpose, nb)
}

func (p *peer) signNonce(purpose protocol.SigningPurpose, nonce []byte) string {
	p.t.Helper()
	message, err := protocol.SigningMessage(purpose, nonce)
	if err != nil {
		p.t.Fatal(err)
	}
	sum := sha256.Sum256(message)
	sig, err := ecdsa.SignASN1(rand.Reader, p.priv, sum[:])
	if err != nil {
		p.t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

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

func (p *peer) register(label string) string {
	p.t.Helper()
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeRegister, false), Label: label})
	ok := unmarshal[protocol.RegisterOK](p.t, p.last(protocol.TypeRegisterOK))
	p.deviceID, p.idCert = ok.DeviceID, ok.IDCert
	return ok.DeviceID
}

func (p *peer) hello(role string) protocol.HelloOK {
	p.t.Helper()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: p.deviceID, Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeHello, false), Role: role})
	return unmarshal[protocol.HelloOK](p.t, p.last(protocol.TypeHelloOK))
}

func TestRegisterMintsNineDigitIDAndIsIdempotent(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("Studio Mac")

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

	if !hn.authority.Verify(id, p.pubB64, first.IDCert) {
		t.Fatal("register_ok carried no valid device-id certificate")
	}

	p.reset()
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeRegister, false)})
	if p.has(protocol.TypeRegisterOK) || p.lastErr().Code != protocol.ErrBadRequest {
		t.Fatalf("a second register on one connection was not refused: %s", p.typesLocked())
	}

	hn.reconnect(p)
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeRegister, false)})
	second := unmarshal[protocol.RegisterOK](t, p.last(protocol.TypeRegisterOK))
	if second.DeviceID != id {
		t.Fatalf("re-registering the same key minted a new id: %q vs %q", second.DeviceID, id)
	}
	if !second.Existing {
		t.Fatal("re-registration reported existing=false")
	}

	q := hn.newPeer()
	id2 := q.register("Laptop")
	if id2 == id {
		t.Fatalf("two distinct keys got the same deviceId %q", id)
	}
}

func TestHelloValidSignatureAuthenticates(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("host")

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

	if len(ok.ICEServers) != 1 || ok.ICEServers[0].URLs[0] != "stun:stun.example:3478" ||
		ok.ICEServers[0].Username != "" || ok.ICEServers[0].Credential != "" {
		t.Fatalf("hello_ok iceServers = %+v, want bare STUN and no credentials", ok.ICEServers)
	}
	if !hn.authority.Verify(id, p.pubB64, ok.IDCert) {
		t.Fatal("hello_ok carried no valid device-id certificate")
	}
}

func TestHelloForgedSignatureRejected(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("host")

	p.reset()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeHello, true), Role: protocol.RoleHost})
	if p.has(protocol.TypeHelloOK) {
		t.Fatal("a forged signature was accepted")
	}
	if got := p.lastErr().Code; got != protocol.ErrBadSignature {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBadSignature)
	}
	if hn.hub.IsOnline(id) {
		t.Fatal("device must not be online after a failed hello")
	}

	other := hn.newPeer()
	p.reset()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: other.pubB64, Sig: other.sigOver(protocol.PurposeHello, p.currentNonce()), Role: protocol.RoleHost})
	if p.has(protocol.TypeHelloOK) {
		t.Fatal("a signature from the wrong key was accepted")
	}
	if got := p.lastErr().Code; got != protocol.ErrUnknownDevice {
		t.Fatalf("another key's valid signature: error code = %q, want %q", got, protocol.ErrUnknownDevice)
	}

	q := hn.newPeer()
	q.deviceID, q.priv, q.pubB64 = id, p.priv, p.pubB64
	q.mu.Lock()
	firstNonce := q.nonce
	q.mu.Unlock()
	goodSig := q.sigOver(protocol.PurposeHello, firstNonce)
	q.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: q.pubB64, Sig: "AAAA", Role: protocol.RoleHost})
	q.reset()
	q.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: q.pubB64, Sig: goodSig, Role: protocol.RoleHost})
	if q.has(protocol.TypeHelloOK) {
		t.Fatal("a signature over a consumed nonce was accepted")
	}
	if got := q.lastErr().Code; got != protocol.ErrBadSignature {
		t.Fatalf("replayed nonce error = %q, want %q", got, protocol.ErrBadSignature)
	}

	q.reset()
	q.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: q.pubB64, Sig: q.sig(protocol.PurposeHello, false), Role: protocol.RoleHost})
	if !q.has(protocol.TypeHelloOK) {
		t.Fatalf("hello with the re-issued nonce failed: %s", q.typesLocked())
	}
}

func TestHelloRequiresAHelloPurposeSignature(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	id := p.register("host")

	p.mu.Lock()
	nonce, err := base64.StdEncoding.DecodeString(p.nonce)
	p.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(nonce)
	raw, err := ecdsa.SignASN1(rand.Reader, p.priv, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	for name, sig := range map[string]string{
		"undomained": base64.StdEncoding.EncodeToString(raw),
		"register":   p.sig(protocol.PurposeRegister, false),
	} {
		p.reset()
		p.send(protocol.TypeHello, protocol.Hello{
			DeviceID: id, Pubkey: p.pubB64, Sig: sig, Role: protocol.RoleHost})
		if p.has(protocol.TypeHelloOK) {
			t.Fatalf("a %s signature authenticated a hello", name)
		}
		if got := p.lastErr().Code; got != protocol.ErrBadSignature {
			t.Fatalf("%s: error code = %q, want %q", name, got, protocol.ErrBadSignature)
		}
	}

	p.reset()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: id, Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeHello, false), Role: protocol.RoleHost})
	if !p.has(protocol.TypeHelloOK) {
		t.Fatalf("a hello-purpose signature over the re-issued nonce failed: %s", p.typesLocked())
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

func (hn *harness) pair(t *testing.T) (host, ctrl *peer) {
	t.Helper()
	host = hn.newPeer()
	host.register("host")
	host.hello(protocol.RoleHost)
	ctrl = hn.newPeer()
	ctrl.register("ctrl")
	ctrl.hello(protocol.RoleController)
	return host, ctrl
}

func TestConnectIsAuthorisedByEntitlement(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)

	ctrl.reset()
	host.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
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

	if ok.HostPubkey != host.pubB64 {
		t.Fatalf("connect_ok hostPubkey = %q, want the host's registered key", ok.HostPubkey)
	}
	if start.HostPubkey != host.pubB64 {
		t.Fatalf("session_start hostPubkey = %q, want the host's registered key", start.HostPubkey)
	}
	if start.ControllerPubkey != ctrl.pubB64 {
		t.Fatalf("session_start controllerPubkey = %q, want the controller's registered key",
			start.ControllerPubkey)
	}
	if got := hn.hub.SessionState(ok.SessionID); got != protocol.SessionOpen {
		t.Fatalf("session state = %q, want %q", got, protocol.SessionOpen)
	}

	time.Sleep(50 * time.Millisecond)
	if starts, stops := hn.ent.reportCounts(); starts != 0 || stops != 0 {
		t.Fatalf("a session was reported before the host proved anything: %d/%d", starts, stops)
	}
	host.send(protocol.TypeSDP, protocol.SDP{SessionID: ok.SessionID, SDPType: "offer", SDP: "v=0\r\n"})
	starts, _ := hn.ent.awaitReports(t, 1, 0)
	if starts[0].SessionID != ok.SessionID || starts[0].HostDeviceID != host.deviceID ||
		starts[0].ControllerDeviceID != ctrl.deviceID {
		t.Fatalf("session start report = %+v", starts[0])
	}

	ctrl.send(protocol.TypeBye, protocol.Bye{SessionID: ok.SessionID, Reason: protocol.ByeUserEnded})
	_, stops := hn.ent.awaitReports(t, 1, 1)
	if stops[0].SessionID != ok.SessionID || stops[0].Reason != protocol.ByeUserEnded {
		t.Fatalf("session stop report = %+v", stops[0])
	}
}

func TestConnectDeniedByEntitlement(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	hn.ent.denyDevice(host.deviceID, protocol.EntitlementNoBalance)

	ctrl.reset()
	host.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if ctrl.has(protocol.TypeConnectOK) {
		t.Fatal("a denied entitlement produced connect_ok")
	}
	e := ctrl.lastErr()
	if e.Code != protocol.ErrEntitlement || e.Reason != protocol.EntitlementNoBalance {
		t.Fatalf("error = %+v, want entitlement/%s", e, protocol.EntitlementNoBalance)
	}
	if host.has(protocol.TypeSessionStart) {
		t.Fatal("host was told about a session that was never created")
	}
}

func TestConnectEntitlementFailureIsInternal(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	hn.ent.failWith(errors.New("internal API unreachable"))

	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if got := ctrl.lastErr().Code; got != protocol.ErrInternal {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrInternal)
	}
}

func TestConnectRejectsAnAccessCode(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)

	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{
		DeviceID: host.deviceID, AccessCode: "SW7K2M9Q"})
	if ctrl.has(protocol.TypeConnectOK) {
		t.Fatal("a v1 connect_req carrying an access code was accepted")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadRequest {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBadRequest)
	}
}

func TestConnectOfflineAndUnknownDevice(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)

	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: "999999999"})
	if got := ctrl.lastErr().Code; got != protocol.ErrUnknownDevice {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrUnknownDevice)
	}

	hn.hub.RemoveClient(host.c)
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if got := ctrl.lastErr().Code; got != protocol.ErrOffline {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrOffline)
	}
}

func TestSecondControllerGetsBusy(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	first := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))

	second := hn.newPeer()
	second.register("ctrl2")
	second.hello(protocol.RoleController)
	second.reset()
	second.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})

	if second.has(protocol.TypeConnectOK) {
		t.Fatal("a second controller was allowed into an active session")
	}
	if got := second.lastErr().Code; got != protocol.ErrBusy {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrBusy)
	}
	if got := hn.hub.SessionState(first.SessionID); got != protocol.SessionOpen {
		t.Fatalf("original session state = %q, want open", got)
	}

	hn.hub.RemoveClient(ctrl.c)
	if got := hn.hub.SessionState(first.SessionID); got != protocol.SessionHalfOpen {
		t.Fatalf("session state after controller drop = %q, want half_open", got)
	}
	second.reset()
	second.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if got := second.lastErr().Code; got != protocol.ErrBusy {
		t.Fatalf("half_open session: error code = %q, want busy", got)
	}

	host.send(protocol.TypeBye, protocol.Bye{SessionID: first.SessionID, Reason: protocol.ByeHostEnded})
	if got := hn.hub.SessionState(first.SessionID); got != "" {
		t.Fatalf("session should be gone after bye, state = %q", got)
	}
	second.reset()
	second.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if !second.has(protocol.TypeConnectOK) {
		t.Fatalf("second controller should connect after bye; got %s", second.typesLocked())
	}
}

func TestSelfConnectRejected(t *testing.T) {
	hn := newHarness(t)
	_, ctrl := hn.pair(t)
	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: ctrl.deviceID})
	if got := ctrl.lastErr().Code; got != protocol.ErrSelfConnect {
		t.Fatalf("error code = %q, want %q", got, protocol.ErrSelfConnect)
	}
}

func TestPresenceGoesOfflineAfterTimeout(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)

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

	hn.clock.Advance(39 * time.Second)
	hn.hub.Sweep()
	if !hn.hub.IsOnline(host.deviceID) {
		t.Fatal("device went offline before the 40s threshold")
	}
	if n := ctrl.count(protocol.TypePresence); n != 1 {
		t.Fatalf("presence pushes after 39s = %d, want 1", n)
	}

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

	host.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	if n := ctrl.count(protocol.TypePresence); n != 3 {
		t.Fatalf("presence pushes after a second heartbeat = %d, want 3", n)
	}
}

func TestPresenceOfflineImmediatelyOnDisconnect(t *testing.T) {
	hn := newHarness(t)
	host, ctrl := hn.pair(t)
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
	host, ctrl := hn.pair(t)
	ctrl.send(protocol.TypeWatch, protocol.Watch{DeviceID: host.deviceID})
	ctrl.send(protocol.TypeUnwatch, protocol.Unwatch{DeviceID: host.deviceID})
	ctrl.reset()
	hn.hub.RemoveClient(host.c)
	if ctrl.has(protocol.TypePresence) {
		t.Fatal("presence was pushed after unwatch")
	}
}

func (hn *harness) openSession(t *testing.T) (host, ctrl *peer, sessionID, hostTok, ctrlTok string) {
	t.Helper()
	host, ctrl = hn.pair(t)
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	ok := unmarshal[protocol.ConnectOK](t, ctrl.last(protocol.TypeConnectOK))
	st := unmarshal[protocol.SessionStart](t, host.last(protocol.TypeSessionStart))
	return host, ctrl, ok.SessionID, st.SessionToken, ok.SessionToken
}

func TestResumeWithValidTokenSurvivesSocketDrop(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, ctrlTok := hn.openSession(t)

	host.reset()
	hn.hub.RemoveClient(ctrl.c)
	if got := hn.hub.SessionState(sid); got != protocol.SessionHalfOpen {
		t.Fatalf("session state after drop = %q, want half_open", got)
	}
	ps := unmarshal[protocol.PeerState](t, host.last(protocol.TypePeerState))
	if ps.Attached || ps.SessionID != sid {
		t.Fatalf("host peer_state = %+v, want detached for %s", ps, sid)
	}

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

	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: r.SessionToken})
	if !ctrl.has(protocol.TypeResumeOK) {
		t.Fatalf("the rotated token should still resume; got %s", ctrl.typesLocked())
	}
}

func TestResumeWithForgedOrExpiredTokenFails(t *testing.T) {
	hn := newHarness(t)
	_, ctrl, sid, _, ctrlTok := hn.openSession(t)
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)

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

	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: "not-a-token"})
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("garbage token error = %q, want %q", got, protocol.ErrBadToken)
	}

	other := auth.NewSigner([]byte("a completely different hmac secret!!"))
	alien := other.Mint(auth.TokenClaims{SessionID: sid, DeviceID: ctrl.deviceID,
		Expiry: hn.clock.Now().Add(time.Hour), Epoch: 1, Nonce: "whatever"})
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: alien})
	if got := ctrl.lastErr().Code; got != protocol.ErrBadToken {
		t.Fatalf("alien token error = %q, want %q", got, protocol.ErrBadToken)
	}

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
	host, ctrl, sid, hostTok, _ := hn.openSession(t)
	_ = host
	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()

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
	host, ctrl, sid, hostTok, ctrlTok := hn.openSession(t)

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
	_, ctrl, sid, _, ctrlTok := hn.openSession(t)

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

func TestSDPAndICERelayVerbatim(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)

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
	zero := 0
	ctrl.send(protocol.TypeICE, protocol.ICE{SessionID: sid, Candidate: cand, SDPMid: "0", SDPMLineIndex: &zero})
	ice := unmarshal[protocol.ICE](t, host.last(protocol.TypeICE))
	if ice.Candidate != cand || ice.SDPMid != "0" || ice.SDPMLineIndex == nil || *ice.SDPMLineIndex != 0 {
		t.Fatalf("relayed ICE = %+v, want candidate %q", ice, cand)
	}

	ctrl.reset()
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: "00000000000000000000000000000000", SDPType: "offer", SDP: body})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("relay to an unknown session: error = %q, want %q", got, protocol.ErrNoSession)
	}

	hn.reconnect(host)
	ctrl.reset()
	ctrl.send(protocol.TypeSDP, protocol.SDP{SessionID: sid, SDPType: "offer", SDP: body})
	if got := ctrl.lastErr().Code; got != protocol.ErrPeerOffline {
		t.Fatalf("relay with peer detached: error = %q, want %q", got, protocol.ErrPeerOffline)
	}
}

func TestPakeIsRelayedLikeSDP(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, _ := hn.openSession(t)

	body := base64.StdEncoding.EncodeToString([]byte("spake2-message-one"))
	host.reset()
	ctrl.send(protocol.TypePake, protocol.Pake{SessionID: sid, Step: 1, Payload: body})
	got := unmarshal[protocol.Pake](t, host.last(protocol.TypePake))
	if got.Payload != body || got.Step != 1 || got.SessionID != sid {
		t.Fatalf("relayed pake = %+v, want step 1 payload %q", got, body)
	}

	ctrl.reset()
	back := base64.StdEncoding.EncodeToString([]byte("spake2-message-two"))
	host.send(protocol.TypePake, protocol.Pake{SessionID: sid, Step: 2, Payload: back})
	if got := unmarshal[protocol.Pake](t, ctrl.last(protocol.TypePake)).Payload; got != back {
		t.Fatalf("relayed payload = %q, want %q", got, back)
	}

	host.reset()
	ctrl.reset()
	ctrl.send(protocol.TypePake, protocol.Pake{
		SessionID: sid, Step: 3, Payload: strings.Repeat("A", protocol.MaxPakePayloadBytes+1)})
	if host.has(protocol.TypePake) {
		t.Fatal("an oversized pake payload was relayed")
	}
	if got := ctrl.lastErr().Code; got != protocol.ErrBadRequest {
		t.Fatalf("oversized pake: error = %q, want %q", got, protocol.ErrBadRequest)
	}

	ctrl.reset()
	ctrl.send(protocol.TypePake, protocol.Pake{
		SessionID: "00000000000000000000000000000000", Step: 1, Payload: body})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("pake to an unknown session: error = %q, want %q", got, protocol.ErrNoSession)
	}
	hn.reconnect(host)
	ctrl.reset()
	ctrl.send(protocol.TypePake, protocol.Pake{SessionID: sid, Step: 3, Payload: body})
	if got := ctrl.lastErr().Code; got != protocol.ErrPeerOffline {
		t.Fatalf("pake with the peer detached: error = %q, want %q", got, protocol.ErrPeerOffline)
	}
}

func TestByeClosesSessionForBothSides(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, ctrlTok := hn.openSession(t)
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

func TestRefreshBumpsTheEpochAndKillsSessions(t *testing.T) {
	hn := newHarness(t)
	host, ctrl, sid, _, ctrlTok := hn.openSession(t)

	before, err := hn.store.GetDevice(host.deviceID)
	if err != nil {
		t.Fatal(err)
	}

	ctrl.reset()
	host.reset()
	hn.clock.Advance(time.Minute)
	host.send(protocol.TypeRefreshCode, map[string]any{})
	ok := unmarshal[protocol.RefreshCodeOK](t, host.last(protocol.TypeRefreshCodeOK))
	if ok.DeviceID != host.deviceID {
		t.Fatalf("refresh_code_ok.deviceId = %q, want %q", ok.DeviceID, host.deviceID)
	}
	if ok.UpdatedAt != hn.clock.Now().UnixMilli() {
		t.Fatalf("refresh_code_ok.updatedAt = %d, want %d", ok.UpdatedAt, hn.clock.Now().UnixMilli())
	}

	after, err := hn.store.GetDevice(host.deviceID)
	if err != nil {
		t.Fatal(err)
	}
	if after.CodeEpoch != before.CodeEpoch+1 {
		t.Fatalf("code epoch = %d, want %d", after.CodeEpoch, before.CodeEpoch+1)
	}

	if got := hn.hub.SessionState(sid); got != "" {
		t.Fatalf("session state after refresh = %q, want gone", got)
	}
	b := unmarshal[protocol.Bye](t, ctrl.last(protocol.TypeBye))
	if b.Reason != protocol.ByeCodeRefreshed || b.SessionID != sid {
		t.Fatalf("controller bye = %+v, want code_refreshed for %s", b, sid)
	}

	hn.reconnect(ctrl)
	ctrl.hello(protocol.RoleController)
	ctrl.reset()
	ctrl.send(protocol.TypeResume, protocol.Resume{SessionID: sid, SessionToken: ctrlTok})
	if got := ctrl.lastErr().Code; got != protocol.ErrNoSession {
		t.Fatalf("resume after refresh: error = %q, want %q", got, protocol.ErrNoSession)
	}

	ctrl.reset()
	ctrl.send(protocol.TypeConnectReq, protocol.ConnectReq{DeviceID: host.deviceID})
	if !ctrl.has(protocol.TypeConnectOK) {
		t.Fatalf("connect after refresh failed: %s", ctrl.typesLocked())
	}
}

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
	id := first.register("host")
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
	host, ctrl, sid, _, _ := hn.openSession(t)
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

func TestRegistryOutageAnswersUnavailableAndNeverMintsAnID(t *testing.T) {
	hn := newHarness(t)
	known := hn.newPeer()
	known.register("Known Mac")

	hn.reg.setDown(true)
	fresh := hn.newPeer()
	fresh.send(protocol.TypeRegister, protocol.Register{Pubkey: fresh.pubB64, Sig: fresh.sig(protocol.PurposeRegister, false)})
	if fresh.has(protocol.TypeRegisterOK) {
		t.Fatal("register succeeded while the registry was down")
	}
	e := fresh.lastErr()
	if e.Code != protocol.ErrUnavailable || e.RetryAfterSec <= 0 {
		t.Fatalf("register during an outage: error = %+v, want unavailable with retryAfterSec", e)
	}
	if _, err := hn.store.GetByPubkey(fresh.pubB64); err == nil {
		t.Fatal("a device id was minted during the outage")
	}

	known.reset()
	known.send(protocol.TypeHello, protocol.Hello{
		DeviceID: known.deviceID, Pubkey: known.pubB64, Sig: known.sig(protocol.PurposeHello, false), Role: protocol.RoleHost})
	if known.has(protocol.TypeHelloOK) {
		t.Fatal("hello succeeded while the registry was down")
	}
	if got := known.lastErr().Code; got != protocol.ErrUnavailable {
		t.Fatalf("hello during an outage: error = %q, want unavailable", got)
	}

	hn.reg.setDown(false)
	known.hello(protocol.RoleHost)
	known.reset()
	hn.reg.setDown(true)
	known.send(protocol.TypeRefreshCode, map[string]any{})
	if got := known.lastErr().Code; got != protocol.ErrUnavailable {
		t.Fatalf("refresh_code during an outage: error = %q, want unavailable", got)
	}
}

// resetBackend loses the registry and, with wipeClaims, the claims database too.
func (hn *harness) resetBackend(wipeClaims bool) {
	hn.t.Helper()
	if wipeClaims {
		hn.claims = filepath.Join(hn.t.TempDir(), "claims.db")
	}
	fresh, err := store.Open(":memory:", hn.claims)
	if err != nil {
		hn.t.Fatal(err)
	}
	hn.t.Cleanup(func() { fresh.Close() })
	hn.store = fresh
	hn.reg.replace(registry.NewLocal(fresh, hn.clock, hn.authority))
}

func (p *peer) reregister(preferred, cert string) protocol.RegisterOK {
	p.t.Helper()
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeRegister, false),
		PreferredDeviceID: preferred, IDCert: cert})
	ok := unmarshal[protocol.RegisterOK](p.t, p.last(protocol.TypeRegisterOK))
	p.deviceID, p.idCert = ok.DeviceID, ok.IDCert
	return ok
}

func (p *peer) helloAs(deviceID, role string) {
	p.t.Helper()
	p.reset()
	p.send(protocol.TypeHello, protocol.Hello{
		DeviceID: deviceID, Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeHello, false), Role: role})
}

func TestReRegisterWithItsCertificateKeepsTheDeviceID(t *testing.T) {
	hn := newHarness(t)
	host := hn.newPeer()
	id := host.register("Studio Mac")
	cert := host.idCert
	hn.hub.RemoveClient(host.c)

	hn.resetBackend(true)
	hn.reconnect(host)
	host.helloAs(id, protocol.RoleHost)
	if got := host.lastErr().Code; got != protocol.ErrUnknownDevice {
		t.Fatalf("hello against a reset backend = %q, want unknown_device", got)
	}

	hn.reconnect(host)
	again := host.reregister(id, cert)
	if again.DeviceID != id || again.Existing || !hn.authority.Verify(id, host.pubB64, again.IDCert) {
		t.Fatalf("re-register = %+v, want the same id %q as a new record with a certificate", again, id)
	}
	if ok := host.hello(protocol.RoleHost); ok.DeviceID != id || !hn.hub.IsOnline(id) {
		t.Fatalf("hello after re-register = %+v online=%v", ok, hn.hub.IsOnline(id))
	}
}

func TestAPreferredIDWithoutACertificateIsNeverHonoured(t *testing.T) {
	hn := newHarness(t)
	host := hn.newPeer()
	id := host.register("Studio Mac")
	cert := host.idCert
	hn.hub.RemoveClient(host.c)
	hn.resetBackend(false)

	for name, attempt := range map[string]struct{ preferred, cert string }{
		"no certificate":            {id, ""},
		"the owner's certificate":   {id, cert},
		"a certificate for another": {"123456789", cert},
		"a free id":                 {"123456789", ""},
	} {
		squatter := hn.newPeer()
		got := squatter.reregister(attempt.preferred, attempt.cert)
		if got.DeviceID == attempt.preferred || !protocol.ValidDeviceID(got.DeviceID) {
			t.Fatalf("%s: a new key was handed %s", name, got.DeviceID)
		}
	}

	bad := hn.newPeer()
	bad.send(protocol.TypeRegister, protocol.Register{
		Pubkey: bad.pubB64, Sig: bad.sig(protocol.PurposeRegister, false), PreferredDeviceID: "12ab"})
	if got := bad.lastErr().Code; got != protocol.ErrBadRequest {
		t.Fatalf("malformed preferredDeviceId = %q, want bad_request", got)
	}
}

func TestADurableClaimKeepsAnIDFromEverChangingHands(t *testing.T) {
	hn := newHarness(t)
	victim := hn.newPeer()
	id := victim.register("Studio Mac")
	cert := victim.idCert
	hn.hub.RemoveClient(victim.c)
	hn.resetBackend(false)

	squatter := hn.newPeer()
	forged, err := hn.authority.Issue(context.Background(), id, squatter.pubB64)
	if err != nil {
		t.Fatal(err)
	}
	if got := squatter.reregister(id, forged); got.DeviceID == id {
		t.Fatalf("a second valid certificate took a claimed id after a registry reset: %+v", got)
	}
	squatter.hello(protocol.RoleHost)

	hn.reconnect(victim)
	if got := victim.reregister(id, cert); got.DeviceID != id || got.Existing {
		t.Fatalf("the claimant did not get its id back: %+v", got)
	}
	victim.hello(protocol.RoleHost)
	for i := 0; i < 3; i++ {
		hn.reconnect(squatter)
		if got := squatter.reregister(id, forged); got.DeviceID == id {
			t.Fatalf("round %d: the id changed hands: %+v", i, got)
		}
		hn.reconnect(victim)
		victim.helloAs(id, protocol.RoleHost)
		if !victim.has(protocol.TypeHelloOK) {
			t.Fatalf("round %d: the claimant lost its id: %s", i, victim.typesLocked())
		}
	}
}

func TestAfterLosingEverythingTheFirstCertifiedClaimantKeepsTheID(t *testing.T) {
	hn := newHarness(t)
	victim := hn.newPeer()
	id := victim.register("Studio Mac")
	cert := victim.idCert
	hn.hub.RemoveClient(victim.c)
	hn.resetBackend(true)

	holder := hn.newPeer()
	holderCert, err := hn.authority.Issue(context.Background(), id, holder.pubB64)
	if err != nil {
		t.Fatal(err)
	}
	if got := holder.reregister(id, holderCert); got.DeviceID != id {
		t.Fatalf("an unclaimed certified id was not restored: %+v", got)
	}
	holder.hello(protocol.RoleHost)
	for i := 0; i < 3; i++ {
		hn.reconnect(victim)
		if got := victim.reregister(id, cert); got.DeviceID == id {
			t.Fatalf("round %d: the id flipped to the second certificate holder", i)
		}
		holder.mu.Lock()
		closed := holder.closed
		holder.mu.Unlock()
		if closed || !hn.hub.IsOnline(id) {
			t.Fatalf("round %d: the claimant was displaced", i)
		}
	}
}

func TestHelloDoesNotRevealWhetherAnIDExists(t *testing.T) {
	hn := newHarness(t)
	owner := hn.newPeer()
	id := owner.register("Studio Mac")
	prober := hn.newPeer()

	answer := func(deviceID, pubkey string, forge bool) string {
		hn.reconnect(prober)
		prober.reset()
		sig := prober.sig(protocol.PurposeHello, forge)
		prober.send(protocol.TypeHello, protocol.Hello{DeviceID: deviceID, Pubkey: pubkey, Sig: sig, Role: protocol.RoleHost})
		e := prober.lastErr()
		return e.Code + "|" + e.Message
	}
	taken := answer(id, prober.pubB64, false)
	free := answer("123456789", prober.pubB64, false)
	if taken != free || !strings.HasPrefix(taken, protocol.ErrUnknownDevice+"|") {
		t.Fatalf("own key: taken id -> %q, free id -> %q; want the same unknown_device", taken, free)
	}
	takenForged := answer(id, owner.pubB64, true)
	freeForged := answer("123456789", owner.pubB64, true)
	if takenForged != freeForged || !strings.HasPrefix(takenForged, protocol.ErrBadSignature+"|") {
		t.Fatalf("someone else's key: taken id -> %q, free id -> %q; want the same bad_signature", takenForged, freeForged)
	}
}

func TestRegisterRefusesNonCanonicalKeysAndTrimsLabels(t *testing.T) {
	hn := newHarness(t)
	p := hn.newPeer()
	p.send(protocol.TypeRegister, protocol.Register{
		Pubkey: p.pubB64[:40] + "\n" + p.pubB64[40:], Sig: p.sig(protocol.PurposeRegister, false)})
	if p.has(protocol.TypeRegisterOK) || p.lastErr().Code != protocol.ErrBadRequest {
		t.Fatalf("a non-canonical key spelling registered: %s", p.typesLocked())
	}
	id := p.register(strings.Repeat("é", 40) + "\x00\x1b")
	d, err := hn.store.GetDevice(id)
	if err != nil {
		t.Fatal(err)
	}
	if d.Label != strings.Repeat("é", 32) {
		t.Fatalf("stored label %q", d.Label)
	}
}

func TestRegisterIsLimitedPerIP(t *testing.T) {
	hn := newHarness(t)
	for i := 0; i < protocol.RegistersPerIPPerHour; i++ {
		hn.newPeer().register("x")
	}
	p := hn.newPeer()
	p.send(protocol.TypeRegister, protocol.Register{Pubkey: p.pubB64, Sig: p.sig(protocol.PurposeRegister, false)})
	e := p.lastErr()
	if p.has(protocol.TypeRegisterOK) || e.Code != protocol.ErrRateLimited || e.RetryAfterSec <= 0 {
		t.Fatalf("register %d from one address = %+v", protocol.RegistersPerIPPerHour+1, e)
	}
	if !p.has(protocol.TypeChallenge) || p.count(protocol.TypeChallenge) < 2 {
		t.Fatal("a refused register must leave the connection able to hello")
	}
	hn.clock.Advance(time.Hour / time.Duration(protocol.RegistersPerIPPerHour))
	q := hn.newPeer()
	q.register("after refill")
}

func TestUnauthenticatedSocketsAreClosedAfterTheAuthTimeout(t *testing.T) {
	hn := newHarness(t)
	idle := hn.newPeer()
	authed := hn.newPeer()
	authed.register("host")
	authed.hello(protocol.RoleHost)

	hn.clock.Advance(AuthTimeout - time.Second)
	idle.send(protocol.TypeHeartbeat, protocol.Heartbeat{})
	hn.hub.Sweep()
	idle.mu.Lock()
	early := idle.closed
	idle.mu.Unlock()
	if early {
		t.Fatal("closed before the auth timeout")
	}
	hn.clock.Advance(2 * time.Second)
	hn.hub.Sweep()
	idle.mu.Lock()
	closed, msg := idle.closed, idle.closeMsg
	idle.mu.Unlock()
	if !closed || msg != "auth_timeout" {
		t.Fatalf("idle unauthenticated socket: closed=%v msg=%q", closed, msg)
	}
	authed.mu.Lock()
	authedClosed := authed.closed
	authed.mu.Unlock()
	if authedClosed || !hn.hub.IsOnline(authed.deviceID) {
		t.Fatal("an authenticated socket was closed by the auth timeout")
	}
}

func TestRegistryCallDoesNotHoldTheHubLock(t *testing.T) {
	hn := newHarness(t)
	online, _ := hn.pair(t)
	slow := hn.newPeer()
	slow.register("Slow Mac")

	release := hn.reg.holdLookups()
	done := make(chan struct{})
	go func() {
		defer close(done)
		slow.send(protocol.TypeHello, protocol.Hello{
			DeviceID: slow.deviceID, Pubkey: slow.pubB64, Sig: slow.sig(protocol.PurposeHello, false), Role: protocol.RoleHost})
	}()

	online.reset()
	beat := make(chan struct{})
	go func() {
		defer close(beat)
		online.send(protocol.TypeHeartbeat, map[string]any{})
	}()
	select {
	case <-beat:
	case <-time.After(2 * time.Second):
		release()
		t.Fatal("a heartbeat blocked behind a pending registry lookup")
	}
	if !online.has(protocol.TypeHeartbeatOK) {
		t.Fatal("no heartbeat_ok while a registry lookup was pending")
	}
	release()
	<-done
	if !slow.has(protocol.TypeHelloOK) {
		t.Fatal("the held hello did not complete once the registry answered")
	}
}
