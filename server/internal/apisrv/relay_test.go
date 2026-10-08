// The relay figure is recorded and priced by nothing (API.md §5.4, BETA.md §3.2).
// Both halves matter: before this, nothing produced the number at all, and the moment
// something does, the thing to prove is that no charge moved.
package apisrv

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	protocol "rcprotocol"
)

// runRelayedSession is runSession with the host's own relay claim attached, which is
// the only way the value can arrive (PROTOCOL.md §2.14.1).
func (h *harness) runRelayedSession(sessionID, hostDeviceID string, d time.Duration,
	bytesRelayed int64) {
	h.t.Helper()
	h.startSession(sessionID, hostDeviceID, h.clock.Now().UnixMilli())
	h.clock.advance(d)
	stop := protocol.SessionStopReport{SessionID: sessionID, EndedAt: h.clock.Now().UnixMilli(),
		Reason: protocol.ByeUserEnded, RelayUsed: true, BytesRelayed: &bytesRelayed}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", stop); r.status != http.StatusNoContent {
		h.t.Fatalf("stop %s: %d %s", sessionID, r.status, r.body)
	}
}

func (h *harness) sessionRows(token string) []protocol.SessionRecord {
	h.t.Helper()
	var page protocol.SessionList
	h.call("GET", protocol.PathSessions+"?since=0", token, "", nil).decode(h.t, &page)
	return page.Sessions
}

func (h *harness) rowFor(token, sessionID string) protocol.SessionRecord {
	h.t.Helper()
	for _, row := range h.sessionRows(token) {
		if row.SessionID == sessionID {
			return row
		}
	}
	h.t.Fatalf("no /v1/sessions row for %s", sessionID)
	return protocol.SessionRecord{}
}

// A relayed session and a peer-to-peer session of the same length cost the same cent
// for cent. This is the assertion API.md §5.4 exists to keep true: the number is a
// measurement, and the day it starts moving a charge, this test is what breaks.
func TestTheRelayFigureIsRecordedAndChargesNothing(t *testing.T) {
	h := newHarness(t)
	const email = "relay@example.com"
	h.link(email, newDevice(t), "SERIAL-RELAY")
	host := h.link(email, newDevice(t), "SERIAL-RELAY")
	h.topUp(email, 500)

	relayed := strings.Repeat("a", 32)
	direct := strings.Repeat("b", 32)

	before := h.balance(email)
	h.runRelayedSession(relayed, host.DeviceID, time.Hour, 377_487_360)
	relayedCost := before - h.balance(email)

	before = h.balance(email)
	h.runSession(direct, host.DeviceID, time.Hour)
	directCost := before - h.balance(email)

	if relayedCost != directCost {
		t.Fatalf("an hour relayed cost %d and an hour peer-to-peer cost %d; "+
			"nothing may price the relay figure (API.md §5.4)", relayedCost, directCost)
	}

	row := h.rowFor(host.DeviceToken, relayed)
	if !row.RelayUsed {
		t.Fatal("the host reported relayUsed and /v1/sessions says false; " +
			"the measurement PHASE5.md §3's cost model rests on is still not recorded")
	}
	if row.BytesRelayed == nil || *row.BytesRelayed != 377_487_360 {
		t.Fatalf("bytesRelayed = %v, want the host's reported 377487360", row.BytesRelayed)
	}

	if other := h.rowFor(host.DeviceToken, direct); other.RelayUsed || other.BytesRelayed != nil {
		t.Fatalf("a peer-to-peer session reported relay use: %+v", other)
	}
}

// A charge is a function of duration and carry, and of nothing else. Running the same
// duration across the whole range of relay claims — none, false, true, true with a
// byte count — must produce one distinct charge, not four.
func TestNoRelayClaimChangesWhatASessionCosts(t *testing.T) {
	h := newHarness(t)
	const email = "relay-invariant@example.com"
	h.link(email, newDevice(t), "SERIAL-INV")
	host := h.link(email, newDevice(t), "SERIAL-INV")
	h.topUp(email, 500)

	bytes := int64(1 << 30)
	claims := []struct {
		name   string
		report protocol.SessionStopReport
	}{
		{"absent", protocol.SessionStopReport{}},
		{"false", protocol.SessionStopReport{RelayUsed: false}},
		{"true, no bytes", protocol.SessionStopReport{RelayUsed: true}},
		{"true, a gigabyte", protocol.SessionStopReport{RelayUsed: true, BytesRelayed: &bytes}},
	}

	costs := map[int64][]string{}
	for i, claim := range claims {
		sessionID := strings.Repeat(fmt.Sprintf("%x", i), 32)
		h.startSession(sessionID, host.DeviceID, h.clock.Now().UnixMilli())
		h.clock.advance(30 * time.Minute)

		report := claim.report
		report.SessionID = sessionID
		report.EndedAt = h.clock.Now().UnixMilli()
		report.Reason = protocol.ByeUserEnded

		before := h.balance(email)
		if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", report); r.status != http.StatusNoContent {
			t.Fatalf("stop %s: %d %s", sessionID, r.status, r.body)
		}
		cost := before - h.balance(email)
		costs[cost] = append(costs[cost], claim.name)
	}

	if len(costs) != 1 {
		t.Fatalf("the same half hour cost differently depending on what the host "+
			"claimed about the relay: %v", costs)
	}
}
