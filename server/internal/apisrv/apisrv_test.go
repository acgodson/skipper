package apisrv

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"rc-signal/internal/apidb"
	"rc-signal/internal/clientip"
	"rc-signal/internal/idcert"
	"rc-signal/internal/idp"
	protocol "rcprotocol"
)

const internalToken = "test-internal-token"

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

type harness struct {
	t           *testing.T
	url         string
	internalURL string
	clock       *clock
	api         *Server
	db          *apidb.DB
	dbPath      string
}

func newHarness(t *testing.T) *harness {
	return newHarnessWith(t, clientip.Resolver{})
}

func newHarnessWith(t *testing.T, proxies clientip.Resolver) *harness {
	t.Helper()
	path := filepath.Join(t.TempDir(), "api.db")
	db, err := apidb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	authority, err := idcert.Ephemeral()
	if err != nil {
		t.Fatal(err)
	}
	c := &clock{now: time.UnixMilli(1_800_000_000_000)}
	api, err := New(Options{
		DB: db, IdP: idp.Dev{}, IDCert: authority, InternalToken: internalToken, HardwareSalt: []byte("salt"),
		ClientIP: proxies, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Now: c.Now,
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)
	internal := httptest.NewServer(api.InternalHandler())
	t.Cleanup(internal.Close)
	return &harness{t: t, url: srv.URL, internalURL: internal.URL, clock: c, api: api, db: db, dbPath: path}
}

type reply struct {
	status int
	header http.Header
	body   []byte
}

func (r reply) decode(t *testing.T, into any) {
	t.Helper()
	if err := json.Unmarshal(r.body, into); err != nil {
		t.Fatalf("decode %s: %v", r.body, err)
	}
}

func (r reply) apiError(t *testing.T) protocol.APIError {
	t.Helper()
	e := protocol.DecodeAPIError(r.body)
	if e.RequestID == "" || e.RequestID != r.header.Get(protocol.HeaderRequestID) {
		t.Fatalf("error envelope requestId %q does not echo X-Request-Id %q", e.RequestID, r.header.Get(protocol.HeaderRequestID))
	}
	return e
}

func (h *harness) call(method, path, credential, idemKey string, body any) reply {
	h.t.Helper()
	base := h.url
	if strings.HasPrefix(path, "/internal/") {
		base = h.internalURL
	}
	return h.callAt(base, method, path, credential, idemKey, body, nil)
}

func (h *harness) callAt(base, method, path, credential, idemKey string, body any, header http.Header) reply {
	h.t.Helper()
	var payload io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			h.t.Fatal(err)
		}
		payload = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, base+path, payload)
	if err != nil {
		h.t.Fatal(err)
	}
	for name, values := range header {
		req.Header[name] = values
	}
	if credential != "" {
		req.Header.Set(protocol.HeaderAuthorization, protocol.BearerPrefix+credential)
	}
	if idemKey != "" {
		req.Header.Set(protocol.HeaderIdempotencyKey, idemKey)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		h.t.Fatal(err)
	}
	if resp.Header.Get(protocol.HeaderRequestID) == "" {
		h.t.Fatalf("%s %s: no X-Request-Id", method, path)
	}
	return reply{status: resp.StatusCode, header: resp.Header, body: raw}
}

func idem() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

type device struct {
	key    *ecdsa.PrivateKey
	pubkey string
}

func newDevice(t *testing.T) device {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return device{key: key, pubkey: base64.StdEncoding.EncodeToString(der)}
}

func (d device) sign(t *testing.T, nonceB64 string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(nonceB64)
	if err != nil {
		t.Fatal(err)
	}
	msg, err := protocol.SigningMessage(protocol.PurposeAPIChallenge, raw)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(msg)
	sig, err := ecdsa.SignASN1(rand.Reader, d.key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

func (h *harness) register(d device) protocol.InternalRegisterResponse {
	h.t.Helper()
	r := h.call("POST", protocol.PathInternalRegister, internalToken, "",
		protocol.InternalRegisterRequest{Pubkey: d.pubkey, Label: "signaling label"})
	if r.status != http.StatusCreated && r.status != http.StatusOK {
		h.t.Fatalf("internal register: %d %s", r.status, r.body)
	}
	var out protocol.InternalRegisterResponse
	r.decode(h.t, &out)
	return out
}

func (h *harness) link(email string, d device, hardwareID string) protocol.DeviceTokenResponse {
	h.t.Helper()
	registered := h.register(d)
	grant := h.redeem(email, d, hardwareID)
	if grant.DeviceID != registered.DeviceID {
		h.t.Fatalf("token deviceId %s, want the signaling id %s", grant.DeviceID, registered.DeviceID)
	}
	return grant
}

const appNonce = "app-nonce"

func (h *harness) mintCode(email string, d device) (code, nonce string) {
	h.t.Helper()
	t := h.t
	r := h.call("POST", protocol.PathAuthLink, "dev:"+email, idem(),
		protocol.LinkRequest{Nonce: appNonce, Pubkey: d.pubkey, Platform: protocol.PlatformMacOS})
	if r.status != http.StatusCreated {
		t.Fatalf("link: %d %s", r.status, r.body)
	}
	var link protocol.LinkResponse
	r.decode(t, &link)
	r = h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{Code: link.Code})
	if r.status != http.StatusOK {
		t.Fatalf("challenge: %d %s", r.status, r.body)
	}
	var challenge protocol.DeviceChallengeResponse
	r.decode(t, &challenge)
	return link.Code, challenge.Nonce
}

func (h *harness) tokenCall(code, nonce string, d device, hardwareID string) reply {
	h.t.Helper()
	return h.tokenCallWithAppNonce(code, appNonce, nonce, d, hardwareID)
}

func (h *harness) tokenCallWithAppNonce(code, linkNonce, nonce string, d device, hardwareID string) reply {
	h.t.Helper()
	return h.call("POST", protocol.PathAuthDeviceToken, "", idem(), protocol.DeviceTokenRequest{
		Code: code, Nonce: linkNonce, Pubkey: d.pubkey, Sig: d.sign(h.t, nonce),
		Platform: protocol.PlatformMacOS, HardwareID: hardwareID, Label: "test mac",
	})
}

func (h *harness) redeem(email string, d device, hardwareID string) protocol.DeviceTokenResponse {
	h.t.Helper()
	t := h.t
	code, nonce := h.mintCode(email, d)
	r := h.tokenCall(code, nonce, d, hardwareID)
	if r.status != http.StatusOK {
		t.Fatalf("token: %d %s", r.status, r.body)
	}
	if bytes.Contains(r.body, []byte(hardwareID)) {
		t.Fatalf("token response leaks the raw hardware id")
	}
	var grant protocol.DeviceTokenResponse
	r.decode(t, &grant)
	return grant
}

func (h *harness) internalEntitlement(deviceID string) (int, string) {
	h.t.Helper()
	r := h.call("GET", protocol.PathInternalEntitlement+"/"+deviceID, internalToken, "", nil)
	if r.status == http.StatusOK {
		var ent protocol.Entitlement
		r.decode(h.t, &ent)
		return r.status, ent.Status
	}
	e := r.apiError(h.t)
	if e.Code != protocol.APIErrEntitlement {
		h.t.Fatalf("internal entitlement %s: %d %s", deviceID, r.status, r.body)
	}
	return r.status, e.Reason
}

func (h *harness) entitlementFor(token string) protocol.Entitlement {
	h.t.Helper()
	r := h.call("GET", protocol.PathEntitlement, token, "", nil)
	if r.status != http.StatusOK {
		h.t.Fatalf("entitlement: %d %s", r.status, r.body)
	}
	var ent protocol.Entitlement
	r.decode(h.t, &ent)
	return ent
}

func TestAuthHandoffRoundTrip(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	grant := h.link("alice@example.com", mac, "SERIAL-A")

	if !protocol.ValidDeviceID(grant.DeviceID) || grant.AccountID == "" || grant.TTLSec != protocol.DeviceTokenTTLSec {
		t.Fatalf("grant = %+v", grant)
	}
	ent := h.entitlementFor(grant.DeviceToken)
	if ent.Status != protocol.StatusTrial || ent.TrialEndsAt == nil {
		t.Fatalf("entitlement = %+v, want trial", ent)
	}

	r := h.call("GET", protocol.PathDevices+"/"+grant.DeviceID, grant.DeviceToken, "", nil)
	if r.status != http.StatusOK || bytes.Contains(r.body, []byte("hardware")) {
		t.Fatalf("own device read: %d %s", r.status, r.body)
	}
	r = h.call("GET", protocol.PathDevices, grant.DeviceToken, "", nil)
	if r.status != http.StatusForbidden || r.apiError(t).Code != protocol.APIErrForbidden {
		t.Fatalf("device token on a user-session endpoint: %d %s", r.status, r.body)
	}
	r = h.call("GET", protocol.PathEntitlement, "dev:alice@example.com", "", nil)
	if r.status != http.StatusForbidden {
		t.Fatalf("user session on a device endpoint: %d %s", r.status, r.body)
	}

	r = h.call("GET", protocol.PathInternalEntitlement+"/"+grant.DeviceID, internalToken, "", nil)
	var internal protocol.Entitlement
	r.decode(t, &internal)
	if r.status != http.StatusOK || internal.Status != protocol.StatusTrial {
		t.Fatalf("internal entitlement: %d %s", r.status, r.body)
	}
	r = h.call("GET", protocol.PathInternalEntitlement+"/"+grant.DeviceID, grant.DeviceToken, "", nil)
	if r.status != http.StatusUnauthorized {
		t.Fatalf("internal surface with a device token: %d", r.status)
	}

	r = h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{DeviceID: grant.DeviceID})
	var challenge protocol.DeviceChallengeResponse
	r.decode(t, &challenge)
	impostor := newDevice(t)
	r = h.call("POST", protocol.PathAuthDeviceRefresh, "", idem(), protocol.DeviceRefreshRequest{
		DeviceID: grant.DeviceID, Pubkey: mac.pubkey, Nonce: challenge.Nonce, Sig: impostor.sign(t, challenge.Nonce),
	})
	if r.status != http.StatusUnauthorized {
		t.Fatalf("refresh signed by another key: %d %s", r.status, r.body)
	}
	r = h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{DeviceID: grant.DeviceID})
	r.decode(t, &challenge)
	r = h.call("POST", protocol.PathAuthDeviceRefresh, "", idem(), protocol.DeviceRefreshRequest{
		DeviceID: grant.DeviceID, Pubkey: mac.pubkey, Nonce: challenge.Nonce, Sig: mac.sign(t, challenge.Nonce),
	})
	var refreshed protocol.DeviceTokenResponse
	r.decode(t, &refreshed)
	if r.status != http.StatusOK || refreshed.DeviceID != grant.DeviceID || refreshed.DeviceToken == grant.DeviceToken {
		t.Fatalf("refresh: %d %s", r.status, r.body)
	}

	r = h.call("POST", protocol.PathAuthDeviceRevoke, grant.DeviceToken, idem(), struct{}{})
	if r.status != http.StatusNoContent {
		t.Fatalf("revoke: %d %s", r.status, r.body)
	}
	r = h.call("GET", protocol.PathEntitlement, grant.DeviceToken, "", nil)
	if r.status != http.StatusUnauthorized || r.apiError(t).Code != protocol.APIErrUnauthenticated {
		t.Fatalf("revoked token still works: %d %s", r.status, r.body)
	}
	if h.entitlementFor(refreshed.DeviceToken).Status != protocol.StatusTrial {
		t.Fatalf("revoking one token must leave the refreshed one working")
	}

	sameMachine := newDevice(t)
	second := h.link("bob@example.com", sameMachine, "SERIAL-A")
	if got := h.entitlementFor(second.DeviceToken); got.Status != protocol.StatusExhausted {
		t.Fatalf("a new key on hardware that already had a trial: %+v, want exhausted", got)
	}
}

func TestSessionsEnforceConcurrencyAndMeter(t *testing.T) {
	h := newHarness(t)
	first := h.link("carol@example.com", newDevice(t), "SERIAL-C1")
	second := h.link("carol@example.com", newDevice(t), "SERIAL-C2")
	if r := h.call("POST", "/v1/credits/dev-topup", "dev:carol@example.com", idem(),
		map[string]int64{"amountCents": 500}); r.status != http.StatusCreated {
		t.Fatalf("dev top-up: %d %s", r.status, r.body)
	}

	start := protocol.SessionStartReport{SessionID: strings.Repeat("a", 32), HostDeviceID: first.DeviceID,
		ControllerDeviceID: "900000001", StartedAt: h.clock.Now().UnixMilli()}
	if r := h.call("POST", protocol.PathInternalSessionStart, internalToken, "", start); r.status != http.StatusNoContent {
		t.Fatalf("start: %d %s", r.status, r.body)
	}

	r := h.call("GET", protocol.PathInternalEntitlement+"/"+second.DeviceID, internalToken, "", nil)
	if r.status != http.StatusPaymentRequired || r.apiError(t).Reason != protocol.EntitlementConcurrency {
		t.Fatalf("second host of the same account while a pair is open: %d %s", r.status, r.body)
	}
	r = h.call("GET", protocol.PathInternalEntitlement+"/"+first.DeviceID, internalToken, "", nil)
	if r.status != http.StatusOK {
		t.Fatalf("the host holding the pair is still entitled: %d %s", r.status, r.body)
	}

	h.clock.advance(61 * time.Second)
	stop := protocol.SessionStopReport{SessionID: start.SessionID, EndedAt: h.clock.Now().UnixMilli(), Reason: "user_ended"}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", stop); r.status != http.StatusNoContent {
		t.Fatalf("stop: %d %s", r.status, r.body)
	}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", stop); r.status != http.StatusNoContent {
		t.Fatalf("a repeated stop must not charge twice: %d %s", r.status, r.body)
	}

	r = h.call("GET", protocol.PathCredits, "dev:carol@example.com", "", nil)
	var balance protocol.Balance
	r.decode(t, &balance)
	if balance.BalanceCents != 498 {
		t.Fatalf("balance after a 61 s session = %d, want 498", balance.BalanceCents)
	}
	if r := h.call("GET", protocol.PathInternalEntitlement+"/"+second.DeviceID, internalToken, "", nil); r.status != http.StatusOK {
		t.Fatalf("the slot is free again after stop: %d %s", r.status, r.body)
	}
}

func TestIdempotencyReplayAndConflict(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	session := "dev:dana@example.com"
	key := idem()
	body := protocol.LinkRequest{Nonce: "n1", Pubkey: mac.pubkey, Platform: protocol.PlatformMacOS}

	first := h.call("POST", protocol.PathAuthLink, session, key, body)
	if first.status != http.StatusCreated || first.header.Get(protocol.HeaderIdempotencyReplayed) != "" {
		t.Fatalf("first call: %d %s", first.status, first.body)
	}
	again := h.call("POST", protocol.PathAuthLink, session, key, body)
	var link protocol.LinkResponse
	first.decode(t, &link)
	if again.status != http.StatusConflict || again.apiError(t).Code != protocol.APIErrReplayUnavailable ||
		bytes.Contains(again.body, []byte(link.Code)) {
		t.Fatalf("replay of a credential-bearing answer: %d %s", again.status, again.body)
	}

	topup := map[string]int64{"amountCents": 500}
	topKey := idem()
	firstTop := h.call("POST", "/v1/credits/dev-topup", session, topKey, topup)
	againTop := h.call("POST", "/v1/credits/dev-topup", session, topKey, topup)
	if firstTop.status != http.StatusCreated || againTop.status != firstTop.status ||
		!bytes.Equal(againTop.body, firstTop.body) || againTop.header.Get(protocol.HeaderIdempotencyReplayed) != "true" {
		t.Fatalf("replay: %d %s (replayed=%q)", againTop.status, againTop.body, againTop.header.Get(protocol.HeaderIdempotencyReplayed))
	}

	changed := body
	changed.Nonce = "n2"
	r := h.call("POST", protocol.PathAuthLink, session, key, changed)
	e := r.apiError(t)
	if r.status != http.StatusConflict || e.Code != protocol.APIErrIdempotencyConflict || e.Reason != protocol.ReasonBodyMismatch {
		t.Fatalf("same key, different body: %d %s", r.status, r.body)
	}

	if r := h.call("POST", protocol.PathAuthLink, "dev:erin@example.com", key, body); r.status != http.StatusCreated ||
		r.header.Get(protocol.HeaderIdempotencyReplayed) != "" {
		t.Fatalf("keys are scoped per account: %d %s", r.status, r.body)
	}

	h.clock.advance(protocol.IdempotencyRetentionSec*time.Second + time.Second)
	if r := h.call("POST", protocol.PathAuthLink, session, key, changed); r.status != http.StatusCreated {
		t.Fatalf("a key is reusable after 24 h: %d %s", r.status, r.body)
	}

	if r := h.call("POST", protocol.PathAuthLink, session, "", body); r.status != http.StatusBadRequest {
		t.Fatalf("missing key: %d", r.status)
	}
	unknown := map[string]string{"nonce": "n3", "pubkey": mac.pubkey, "platform": "macos", "surprise": "x"}
	if r := h.call("POST", protocol.PathAuthLink, session, idem(), unknown); r.status != http.StatusBadRequest ||
		r.apiError(t).Code != protocol.APIErrBadRequest {
		t.Fatalf("unknown member: %d %s", r.status, r.body)
	}
}

func TestTokenLinksTheDeviceSignalingRegistered(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)

	code, nonce := h.mintCode("frank@example.com", mac)
	r := h.tokenCall(code, nonce, mac, "SERIAL-F")
	if e := r.apiError(t); r.status != http.StatusBadRequest || e.Code != protocol.APIErrBadRequest ||
		e.Reason != protocol.ReasonUnregistered {
		t.Fatalf("token for a key signaling never registered: %d %s", r.status, r.body)
	}

	first := h.register(mac)
	again := h.register(mac)
	if !protocol.ValidDeviceID(first.DeviceID) || first.Existing || !again.Existing || again.DeviceID != first.DeviceID {
		t.Fatalf("register is not idempotent by pubkey: %+v then %+v", first, again)
	}
	if status, got := h.internalEntitlement(first.DeviceID); status != http.StatusPaymentRequired ||
		got != protocol.EntitlementUnlinked {
		t.Fatalf("registered but never linked: %d %s, want 402 unlinked", status, got)
	}

	r = h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{Code: code})
	var challenge protocol.DeviceChallengeResponse
	r.decode(t, &challenge)
	r = h.tokenCall(code, challenge.Nonce, mac, "SERIAL-F")
	var grant protocol.DeviceTokenResponse
	r.decode(t, &grant)
	if r.status != http.StatusOK || grant.DeviceID != first.DeviceID {
		t.Fatalf("token after register: %d %s, want deviceId %s", r.status, r.body, first.DeviceID)
	}
	if ent := h.entitlementFor(grant.DeviceToken); ent.Status != protocol.StatusTrial {
		t.Fatalf("the trial starts at first link: %+v", ent)
	}
	if status, got := h.internalEntitlement(first.DeviceID); status != http.StatusOK || got != protocol.StatusTrial {
		t.Fatalf("linked device: %d %s, want 200 trial", status, got)
	}

	r = h.call("GET", protocol.InternalDevicePath(first.DeviceID), internalToken, "", nil)
	var dev protocol.InternalDevice
	r.decode(t, &dev)
	if r.status != http.StatusOK || dev.Pubkey != mac.pubkey || dev.CodeEpoch != 1 {
		t.Fatalf("internal device read: %d %s", r.status, r.body)
	}
	r = h.call("POST", protocol.InternalEpochPath(first.DeviceID), internalToken, "", struct{}{})
	r.decode(t, &dev)
	if r.status != http.StatusOK || dev.CodeEpoch != 2 {
		t.Fatalf("epoch bump: %d %s", r.status, r.body)
	}
	if r := h.call("GET", protocol.InternalDevicePath(first.DeviceID), grant.DeviceToken, "", nil); r.status != http.StatusUnauthorized {
		t.Fatalf("internal device read with a device token: %d", r.status)
	}

	if r := h.call("DELETE", protocol.PathDevices+"/"+first.DeviceID, "dev:frank@example.com", idem(), nil); r.status != http.StatusNoContent {
		t.Fatalf("unlink: %d %s", r.status, r.body)
	}
	if status, got := h.internalEntitlement(first.DeviceID); status != http.StatusPaymentRequired ||
		got != protocol.EntitlementUnlinked {
		t.Fatalf("unlinked device: %d %s, want 402 unlinked", status, got)
	}
	relinked := h.redeem("frank@example.com", mac, "SERIAL-F")
	if relinked.DeviceID != first.DeviceID || h.entitlementFor(relinked.DeviceToken).Status != protocol.StatusTrial {
		t.Fatalf("re-link keeps the id and the original trial: %+v", relinked)
	}
}

func TestUnknownDeviceIsUnlinkedAndNeverProvisioned(t *testing.T) {
	h := newHarness(t)
	for i := 0; i < 2; i++ {
		if status, got := h.internalEntitlement("123456789"); status != http.StatusPaymentRequired ||
			got != protocol.EntitlementUnlinked {
			t.Fatalf("unknown device: %d %s, want 402 unlinked", status, got)
		}
	}
	r := h.call("GET", protocol.InternalDevicePath("123456789"), internalToken, "", nil)
	if r.status != http.StatusNotFound {
		t.Fatalf("an entitlement query created a device record: %d %s", r.status, r.body)
	}
	if r := h.call("POST", protocol.InternalEpochPath("123456789"), internalToken, "", struct{}{}); r.status != http.StatusNotFound {
		t.Fatalf("epoch bump for an unknown device: %d %s", r.status, r.body)
	}
}

func TestDevExpireTrialEndsTheAccountsTrial(t *testing.T) {
	h := newHarness(t)
	grant := h.link("gina@example.com", newDevice(t), "SERIAL-G")
	if r := h.call("POST", "/v1/dev/expire-trial", "dev:gina@example.com", "", struct{}{}); r.status != http.StatusNoContent {
		t.Fatalf("expire-trial: %d %s", r.status, r.body)
	}
	if status, got := h.internalEntitlement(grant.DeviceID); status != http.StatusPaymentRequired ||
		got != protocol.EntitlementTrialExpired {
		t.Fatalf("after expire-trial: %d %s, want 402 trial_expired", status, got)
	}
	if r := h.call("POST", "/v1/dev/expire-trial", grant.DeviceToken, "", struct{}{}); r.status != http.StatusForbidden {
		t.Fatalf("expire-trial with a device token: %d %s", r.status, r.body)
	}
}

func (h *harness) challenge(code string) string {
	h.t.Helper()
	r := h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{Code: code})
	var challenge protocol.DeviceChallengeResponse
	r.decode(h.t, &challenge)
	return challenge.Nonce
}

func TestTokenRequiresTheLinkNonceAndBurnsTheCodeOnMismatch(t *testing.T) {
	for name, presented := range map[string]string{"wrong": "attacker-nonce", "missing": ""} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			mac := newDevice(t)
			h.register(mac)
			code, nonce := h.mintCode("hana@example.com", mac)
			r := h.tokenCallWithAppNonce(code, presented, nonce, mac, "SERIAL-H")
			if e := r.apiError(t); r.status != http.StatusBadRequest || e.Code != protocol.APIErrBadRequest ||
				e.Reason != protocol.ReasonNonceMismatch {
				t.Fatalf("%s nonce: %d %s", name, r.status, r.body)
			}
			r = h.tokenCall(code, h.challenge(code), mac, "SERIAL-H")
			if r.status != http.StatusUnauthorized || r.apiError(t).Code != protocol.APIErrUnauthenticated {
				t.Fatalf("the code survived a %s nonce: %d %s", name, r.status, r.body)
			}
		})
	}
}

func TestTokenCodeCannotBeReplayed(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	h.register(mac)
	code, nonce := h.mintCode("ivan@example.com", mac)
	if r := h.tokenCall(code, nonce, mac, "SERIAL-I"); r.status != http.StatusOK {
		t.Fatalf("first redeem: %d %s", r.status, r.body)
	}
	r := h.tokenCall(code, h.challenge(code), mac, "SERIAL-I")
	if r.status != http.StatusUnauthorized || r.apiError(t).Code != protocol.APIErrUnauthenticated {
		t.Fatalf("replayed code with the right nonce: %d %s", r.status, r.body)
	}
}

func TestDevLinkPageEchoesTheAppNonce(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	form := url.Values{"nonce": {"nonce-from-app"}, "device": {mac.pubkey}, "email": {"jo@example.com"}}
	resp, err := http.PostForm(h.url+"/link", form)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	page, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || !bytes.Contains(page, []byte("nonce=nonce-from-app")) {
		t.Fatalf("handoff page: %d %s", resp.StatusCode, page)
	}
}
