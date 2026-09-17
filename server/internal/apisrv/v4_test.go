package apisrv

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"rc-signal/internal/clientip"
	protocol "rcprotocol"
)

func (h *harness) deviceChallenge(deviceID string) string {
	h.t.Helper()
	r := h.call("POST", protocol.PathAuthDeviceChallenge, "", "", protocol.DeviceChallengeRequest{DeviceID: deviceID})
	if r.status != http.StatusOK {
		h.t.Fatalf("challenge for %s: %d %s", deviceID, r.status, r.body)
	}
	var c protocol.DeviceChallengeResponse
	r.decode(h.t, &c)
	return c.Nonce
}

func (h *harness) refresh(d device, deviceID, nonce string) reply {
	h.t.Helper()
	return h.call("POST", protocol.PathAuthDeviceRefresh, "", idem(), protocol.DeviceRefreshRequest{
		DeviceID: deviceID, Pubkey: d.pubkey, Nonce: nonce, Sig: d.sign(h.t, nonce)})
}

func TestTheInternalSurfaceIsNotOnThePublicListener(t *testing.T) {
	h := newHarness(t)
	grant := h.link("a@example.com", newDevice(t), "SERIAL-1")
	for _, path := range []string{
		protocol.PathInternalEntitlement + "/" + grant.DeviceID,
		protocol.InternalDevicePath(grant.DeviceID),
	} {
		if r := h.callAt(h.url, "GET", path, internalToken, "", nil, nil); r.status != http.StatusNotFound {
			t.Fatalf("public %s: %d %s", path, r.status, r.body)
		}
		if r := h.callAt(h.internalURL, "GET", path, "", "", nil, nil); r.status != http.StatusUnauthorized {
			t.Fatalf("internal %s without the bearer: %d", path, r.status)
		}
		if r := h.callAt(h.internalURL, "GET", path, internalToken, "", nil, nil); r.status != http.StatusOK {
			t.Fatalf("internal %s: %d %s", path, r.status, r.body)
		}
	}
	if r := h.callAt(h.internalURL, "GET", protocol.PathEntitlement, grant.DeviceToken, "", nil, nil); r.status != http.StatusNotFound {
		t.Fatalf("the internal listener serves public paths: %d", r.status)
	}
}

func TestRefreshVerifiesTheNonceTheDeviceSigned(t *testing.T) {
	h := newHarness(t)
	victim := newDevice(t)
	grant := h.link("v@example.com", victim, "hw-1")

	signed := h.deviceChallenge(grant.DeviceID)
	h.clock.advance(time.Second)
	h.deviceChallenge(grant.DeviceID)
	if r := h.refresh(victim, grant.DeviceID, signed); r.status != http.StatusOK {
		t.Fatalf("a stranger's newer challenge broke the victim's refresh: %d %s", r.status, r.body)
	}
	if r := h.refresh(victim, grant.DeviceID, signed); r.status != http.StatusUnauthorized {
		t.Fatalf("a spent nonce refreshed again: %d %s", r.status, r.body)
	}

	other := h.link("o@example.com", newDevice(t), "hw-2")
	foreign := h.deviceChallenge(other.DeviceID)
	if r := h.refresh(victim, grant.DeviceID, foreign); r.status != http.StatusUnauthorized {
		t.Fatalf("a nonce issued for another device was accepted: %d %s", r.status, r.body)
	}
	expired := h.deviceChallenge(grant.DeviceID)
	h.clock.advance(protocol.APINonceTTLSec*time.Second + time.Second)
	if r := h.refresh(victim, grant.DeviceID, expired); r.status != http.StatusUnauthorized {
		t.Fatalf("an expired nonce was accepted: %d %s", r.status, r.body)
	}
	if r := h.call("POST", protocol.PathAuthDeviceRefresh, "", idem(), protocol.DeviceRefreshRequest{
		DeviceID: grant.DeviceID, Pubkey: victim.pubkey, Sig: victim.sign(t, h.deviceChallenge(grant.DeviceID)),
	}); r.status != http.StatusBadRequest {
		t.Fatalf("a refresh without the signed nonce: %d %s", r.status, r.body)
	}
}

func TestStrangersCannotSpendAVictimsRefreshBudget(t *testing.T) {
	h := newHarness(t)
	victim := newDevice(t)
	grant := h.link("v@example.com", victim, "hw-1")
	stranger := newDevice(t)
	for i := 0; i < 20; i++ {
		junk := h.deviceChallenge(grant.DeviceID)
		if i%2 == 0 {
			h.call("POST", protocol.PathAuthDeviceRefresh, "", idem(), protocol.DeviceRefreshRequest{
				DeviceID: grant.DeviceID, Pubkey: victim.pubkey, Nonce: junk, Sig: "AAAA"})
			continue
		}
		if r := h.refresh(stranger, grant.DeviceID, junk); r.status != http.StatusForbidden {
			t.Fatalf("a stranger's own-key refresh: %d %s", r.status, r.body)
		}
		h.clock.advance(3 * time.Minute)
	}
	if r := h.refresh(victim, grant.DeviceID, h.deviceChallenge(grant.DeviceID)); r.status != http.StatusOK {
		t.Fatalf("victim refresh after 20 stranger calls: %d %s", r.status, r.body)
	}
	for i := 0; i < 11; i++ {
		if r := h.refresh(victim, grant.DeviceID, h.deviceChallenge(grant.DeviceID)); r.status != http.StatusOK {
			t.Fatalf("refresh %d of the device's own budget: %d %s", i+2, r.status, r.body)
		}
		h.clock.advance(3 * time.Minute)
	}
	r := h.refresh(victim, grant.DeviceID, h.deviceChallenge(grant.DeviceID))
	if r.status != http.StatusTooManyRequests || r.apiError(t).RetryAfterSec <= 0 {
		t.Fatalf("13th signed refresh in a day: %d %s", r.status, r.body)
	}
}

func TestCredentialsAreNeverStoredOrReplayed(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	h.register(mac)
	code, nonce := h.mintCode("w@example.com", mac)
	key := idem()
	request := protocol.DeviceTokenRequest{
		Code: code, Nonce: appNonce, Pubkey: mac.pubkey, Sig: mac.sign(t, nonce),
		Platform: protocol.PlatformMacOS, HardwareID: "SERIAL-W",
	}
	first := h.call("POST", protocol.PathAuthDeviceToken, "", key, request)
	if first.status != http.StatusOK {
		t.Fatalf("token: %d %s", first.status, first.body)
	}
	var grant protocol.DeviceTokenResponse
	first.decode(t, &grant)
	replay := h.call("POST", protocol.PathAuthDeviceToken, "", key, request)
	if replay.status != http.StatusConflict || replay.apiError(t).Code != protocol.APIErrReplayUnavailable ||
		bytes.Contains(replay.body, []byte(grant.DeviceToken)) {
		t.Fatalf("token replay: %d %s", replay.status, replay.body)
	}
	if h.entitlementFor(grant.DeviceToken).Status == "" {
		t.Fatal("the issued token does not work")
	}
	refreshed := h.refresh(mac, grant.DeviceID, h.deviceChallenge(grant.DeviceID))
	var second protocol.DeviceTokenResponse
	refreshed.decode(t, &second)

	raw, err := os.ReadFile(h.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	wal, _ := os.ReadFile(h.dbPath + "-wal")
	for name, secret := range map[string]string{
		"device token": grant.DeviceToken, "refreshed token": second.DeviceToken,
		"link code": code, "hardware id": "SERIAL-W",
	} {
		if secret == "" {
			t.Fatalf("%s is empty", name)
		}
		if bytes.Contains(raw, []byte(secret)) || bytes.Contains(wal, []byte(secret)) {
			t.Fatalf("the database files hold the plaintext %s", name)
		}
	}
	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var hits int
	if err := db.QueryRow(`SELECT
 (SELECT COUNT(1) FROM idempotency WHERE instr(CAST(response AS TEXT), ?) > 0) +
 (SELECT COUNT(1) FROM link_codes_v2 WHERE code_hash = ?) +
 (SELECT COUNT(1) FROM nonces_v2 WHERE code_hash = ?)`,
		grant.DeviceToken, code, code).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 0 {
		t.Fatalf("%d rows hold a plaintext credential", hits)
	}
}

func TestForwardedForIsTrustedOnlyFromConfiguredProxies(t *testing.T) {
	spoof := func(h *harness, ip string) int {
		header := http.Header{}
		header.Set(protocol.HeaderForwardedFor, ip)
		return h.callAt(h.url, "GET", "/v1/health", "", "", nil, header).status
	}
	direct := newHarness(t)
	for i := 0; i < 60; i++ {
		spoof(direct, "198.51.100."+string(rune('0'+i%10)))
	}
	if got := spoof(direct, "203.0.113.77"); got != http.StatusTooManyRequests {
		t.Fatalf("an untrusted X-Forwarded-For escaped the per-IP limit: %d", got)
	}

	trusted, err := clientip.Parse("127.0.0.1/32, ::1/128")
	if err != nil {
		t.Fatal(err)
	}
	proxied := newHarnessWith(t, trusted)
	for i := 0; i < 60; i++ {
		if got := spoof(proxied, "198.51.100.1"); got != http.StatusOK {
			t.Fatalf("call %d from one forwarded client: %d", i, got)
		}
	}
	if got := spoof(proxied, "198.51.100.1"); got != http.StatusTooManyRequests {
		t.Fatalf("the forwarded client was not limited: %d", got)
	}
	if got := spoof(proxied, "198.51.100.2"); got != http.StatusOK {
		t.Fatalf("a second client behind the same proxy shares the bucket: %d", got)
	}
}

func (h *harness) startSession(id, hostID string, startedAt int64) {
	h.t.Helper()
	r := h.call("POST", protocol.PathInternalSessionStart, internalToken, "", protocol.SessionStartReport{
		SessionID: id, HostDeviceID: hostID, ControllerDeviceID: "900000001", StartedAt: startedAt})
	if r.status != http.StatusNoContent {
		h.t.Fatalf("start %s: %d %s", id, r.status, r.body)
	}
}

func (h *harness) balance(email string) int64 {
	h.t.Helper()
	var b protocol.Balance
	h.call("GET", protocol.PathCredits, "dev:"+email, "", nil).decode(h.t, &b)
	return b.BalanceCents
}

func TestASubMinuteSessionIsFree(t *testing.T) {
	h := newHarness(t)
	host := h.link("f@example.com", newDevice(t), "SERIAL-F1")
	h.call("POST", "/v1/credits/dev-topup", "dev:f@example.com", idem(), map[string]int64{"amountCents": 500})
	id := strings.Repeat("b", 32)
	h.startSession(id, host.DeviceID, h.clock.Now().UnixMilli())
	stop := protocol.SessionStopReport{SessionID: id, EndedAt: h.clock.Now().Add(59 * time.Second).UnixMilli(), Reason: protocol.ByeAuthFailed}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", stop); r.status != http.StatusNoContent {
		t.Fatalf("stop: %d %s", r.status, r.body)
	}
	if got := h.balance("f@example.com"); got != 500 {
		t.Fatalf("a 59 s session cost %d cents", 500-got)
	}
	bad := protocol.SessionStopReport{SessionID: strings.Repeat("c", 32), Reason: strings.Repeat("A", 70*1024)}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", bad); r.status == http.StatusNoContent {
		t.Fatal("a stop report with a free-form reason was accepted")
	}
}

func TestReconciliationClosesRowsSignalingForgot(t *testing.T) {
	h := newHarness(t)
	host := h.link("r@example.com", newDevice(t), "SERIAL-R1")
	other := h.link("r2@example.com", newDevice(t), "SERIAL-R2")
	h.call("POST", "/v1/credits/dev-topup", "dev:r@example.com", idem(), map[string]int64{"amountCents": 500})
	h.call("POST", "/v1/credits/dev-topup", "dev:r2@example.com", idem(), map[string]int64{"amountCents": 500})
	start := h.clock.Now().UnixMilli()
	lost, live := strings.Repeat("d", 32), strings.Repeat("e", 32)
	h.startSession(lost, host.DeviceID, start)
	h.startSession(live, other.DeviceID, start)

	down := func(context.Context) (protocol.InternalLiveSessions, error) {
		return protocol.InternalLiveSessions{}, errors.New("signaling unreachable")
	}
	if closed, err := h.api.Reconcile(context.Background(), down); err == nil || closed != 0 {
		t.Fatalf("an unreachable signaling closed %d rows (err=%v)", closed, err)
	}

	seen := start + (5 * time.Minute).Milliseconds()
	both := func(context.Context) (protocol.InternalLiveSessions, error) {
		return protocol.InternalLiveSessions{SessionIDs: []string{lost, live}, ServerTime: seen}, nil
	}
	if closed, err := h.api.Reconcile(context.Background(), both); err != nil || closed != 0 {
		t.Fatalf("live sessions were closed: %d %v", closed, err)
	}
	onlyLive := func(context.Context) (protocol.InternalLiveSessions, error) {
		return protocol.InternalLiveSessions{SessionIDs: []string{live}, ServerTime: seen + time.Hour.Milliseconds()}, nil
	}
	if closed, err := h.api.Reconcile(context.Background(), onlyLive); err != nil || closed != 1 {
		t.Fatalf("reconcile closed %d rows (err=%v), want 1", closed, err)
	}
	if got := h.balance("r@example.com"); got != 495 {
		t.Fatalf("the forgotten session was billed %d cents, want 5 (to its last sighting)", 500-got)
	}
	if got := h.balance("r2@example.com"); got != 500 {
		t.Fatalf("the live session was billed %d cents", 500-got)
	}
	r := h.call("GET", protocol.PathInternalEntitlement+"/"+host.DeviceID, internalToken, "", nil)
	if r.status != http.StatusOK {
		t.Fatalf("the host is still blocked by a forgotten row: %d %s", r.status, r.body)
	}
	late := protocol.SessionStopReport{SessionID: lost, EndedAt: seen + time.Hour.Milliseconds(), Reason: protocol.ByeUserEnded}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", late); r.status != http.StatusNoContent {
		t.Fatalf("a late stop: %d %s", r.status, r.body)
	}
	if got := h.balance("r@example.com"); got != 495 {
		t.Fatalf("a late stop billed the reconciled session again: %d", 500-got)
	}
}

func TestInternalRegisterRefusesNonCanonicalKeys(t *testing.T) {
	h := newHarness(t)
	mac := newDevice(t)
	r := h.call("POST", protocol.PathInternalRegister, internalToken, "",
		protocol.InternalRegisterRequest{Pubkey: mac.pubkey + "\n"})
	if r.status != http.StatusBadRequest {
		t.Fatalf("non-canonical key: %d %s", r.status, r.body)
	}
}
