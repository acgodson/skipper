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
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"rc-signal/internal/apidb"
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
	t     *testing.T
	url   string
	clock *clock
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	db, err := apidb.Open(filepath.Join(t.TempDir(), "api.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	c := &clock{now: time.UnixMilli(1_800_000_000_000)}
	api, err := New(Options{
		DB: db, IdP: idp.Dev{}, InternalToken: internalToken, HardwareSalt: []byte("salt"),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Now: c.Now,
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)
	return &harness{t: t, url: srv.URL, clock: c}
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
	var payload io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			h.t.Fatal(err)
		}
		payload = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, h.url+path, payload)
	if err != nil {
		h.t.Fatal(err)
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
	sum := sha256.Sum256(raw)
	sig, err := ecdsa.SignASN1(rand.Reader, d.key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

func (h *harness) link(email string, d device, hardwareID string) protocol.DeviceTokenResponse {
	h.t.Helper()
	t := h.t
	r := h.call("POST", protocol.PathAuthLink, "dev:"+email, idem(),
		protocol.LinkRequest{Nonce: "app-nonce", Pubkey: d.pubkey, Platform: protocol.PlatformMacOS})
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

	r = h.call("POST", protocol.PathAuthDeviceToken, "", idem(), protocol.DeviceTokenRequest{
		Code: link.Code, Pubkey: d.pubkey, Sig: d.sign(t, challenge.Nonce),
		Platform: protocol.PlatformMacOS, HardwareID: hardwareID, Label: "test mac",
	})
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
		DeviceID: grant.DeviceID, Pubkey: mac.pubkey, Sig: impostor.sign(t, challenge.Nonce),
	})
	if r.status != http.StatusUnauthorized {
		t.Fatalf("refresh signed by another key: %d %s", r.status, r.body)
	}
	r = h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{DeviceID: grant.DeviceID})
	r.decode(t, &challenge)
	r = h.call("POST", protocol.PathAuthDeviceRefresh, "", idem(), protocol.DeviceRefreshRequest{
		DeviceID: grant.DeviceID, Pubkey: mac.pubkey, Sig: mac.sign(t, challenge.Nonce),
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
	if again.status != http.StatusCreated || !bytes.Equal(again.body, first.body) ||
		again.header.Get(protocol.HeaderIdempotencyReplayed) != "true" {
		t.Fatalf("replay: %d %s (replayed=%q)", again.status, again.body, again.header.Get(protocol.HeaderIdempotencyReplayed))
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
