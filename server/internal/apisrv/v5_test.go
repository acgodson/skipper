package apisrv

import (
	"net/http"
	"testing"

	protocol "rcprotocol"
)

func TestOnlyTheCertifyCallSignsAndOnlyForTheOwningKey(t *testing.T) {
	h := newHarness(t)
	owner := newDevice(t)
	grant := h.link("cert@example.com", owner, "SERIAL-C")

	r := h.call("GET", protocol.InternalDevicePath(grant.DeviceID), internalToken, "", nil)
	var read protocol.InternalDevice
	r.decode(t, &read)
	if r.status != http.StatusOK || read.IDCert != "" || read.Pubkey != owner.pubkey {
		t.Fatalf("a plain lookup must not sign: %d %s", r.status, r.body)
	}
	r = h.call("POST", protocol.InternalEpochPath(grant.DeviceID), internalToken, "", struct{}{})
	if r.decode(t, &read); r.status != http.StatusOK || read.IDCert != "" {
		t.Fatalf("an epoch bump must not sign: %d %s", r.status, r.body)
	}

	r = h.call("POST", protocol.InternalCertPath(grant.DeviceID), internalToken, "", protocol.InternalCertRequest{Pubkey: owner.pubkey})
	var certified protocol.InternalDevice
	r.decode(t, &certified)
	if r.status != http.StatusOK || !h.authority.Verify(grant.DeviceID, owner.pubkey, certified.IDCert) {
		t.Fatalf("certify for the owning key: %d %s", r.status, r.body)
	}
	for name, call := range map[string]struct{ id, pubkey string }{
		"another key":    {grant.DeviceID, newDevice(t).pubkey},
		"an unknown id":  {"123456789", owner.pubkey},
		"an empty key":   {grant.DeviceID, ""},
		"a bad id shape": {"12345", owner.pubkey},
	} {
		r := h.call("POST", protocol.InternalCertPath(call.id), internalToken, "", protocol.InternalCertRequest{Pubkey: call.pubkey})
		if r.status != http.StatusNotFound && r.status != http.StatusBadRequest {
			t.Fatalf("certify for %s: %d %s", name, r.status, r.body)
		}
		var body protocol.InternalDevice
		if r.decode(t, &body); body.IDCert != "" {
			t.Fatalf("certify for %s returned a certificate", name)
		}
	}
	if r := h.callAt(h.url, "POST", protocol.InternalCertPath(grant.DeviceID), internalToken, "", protocol.InternalCertRequest{Pubkey: owner.pubkey}, nil); r.status != http.StatusNotFound {
		t.Fatalf("certify on the public listener: %d", r.status)
	}
}

func TestAPairBecomesKnownWhenItsSessionIsMetered(t *testing.T) {
	h := newHarness(t)
	host := h.link("pair@example.com", newDevice(t), "SERIAL-H")
	ctrl := h.link("pair@example.com", newDevice(t), "SERIAL-K")
	known := func(hostID, ctrlID string) bool {
		t.Helper()
		r := h.call("GET", protocol.InternalPairPath(hostID, ctrlID), internalToken, "", nil)
		var pair protocol.InternalPair
		r.decode(t, &pair)
		if r.status != http.StatusOK {
			t.Fatalf("pair %s/%s: %d %s", hostID, ctrlID, r.status, r.body)
		}
		return pair.Known
	}
	if known(host.DeviceID, ctrl.DeviceID) {
		t.Fatal("a pair without a metered session is known")
	}
	r := h.call("POST", protocol.PathInternalSessionStart, internalToken, "", protocol.SessionStartReport{
		SessionID: "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", HostDeviceID: host.DeviceID, ControllerDeviceID: ctrl.DeviceID,
		StartedAt: h.clock.Now().UnixMilli()})
	if r.status != http.StatusNoContent {
		t.Fatalf("session start: %d %s", r.status, r.body)
	}
	if !known(host.DeviceID, ctrl.DeviceID) || known(ctrl.DeviceID, host.DeviceID) {
		t.Fatal("the metered pair is not known in exactly its own direction")
	}
	if r := h.call("GET", protocol.InternalPairPath(host.DeviceID, "12ab"), internalToken, "", nil); r.status != http.StatusBadRequest {
		t.Fatalf("a malformed pair: %d", r.status)
	}
	if r := h.callAt(h.url, "GET", protocol.InternalPairPath(host.DeviceID, ctrl.DeviceID), internalToken, "", nil, nil); r.status != http.StatusNotFound {
		t.Fatalf("pair on the public listener: %d", r.status)
	}
	if r := h.call("GET", protocol.InternalPairPath(host.DeviceID, ctrl.DeviceID), "", "", nil); r.status != http.StatusUnauthorized {
		t.Fatalf("pair without the bearer: %d", r.status)
	}
}
