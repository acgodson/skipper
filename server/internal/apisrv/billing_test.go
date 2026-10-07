// Billing acceptance: the balance floor, the hourly rate's carry, and the trial as
// credit (BETA.md §1.2, §1.3, §3.1). These run the real handlers over the real
// ledger, because the bug they exist to prevent is arithmetic a unit test of
// policy alone cannot see.
package apisrv

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"rc-signal/internal/policy"
	protocol "rcprotocol"
)

func (h *harness) topUp(email string, cents int64) {
	h.t.Helper()
	r := h.call("POST", "/v1/credits/dev-topup", "dev:"+email, idem(),
		map[string]int64{"amountCents": cents})
	if r.status != http.StatusCreated {
		h.t.Fatalf("top up %d: %d %s", cents, r.status, r.body)
	}
}

func (h *harness) ledger(email string) []protocol.LedgerEntry {
	h.t.Helper()
	var page protocol.LedgerPage
	h.call("GET", protocol.PathCreditsLedger+"?since=0", "dev:"+email, "", nil).decode(h.t, &page)
	return page.Entries
}

func (h *harness) entriesOfType(email, entryType string) []protocol.LedgerEntry {
	h.t.Helper()
	var out []protocol.LedgerEntry
	for _, e := range h.ledger(email) {
		if e.Type == entryType {
			out = append(out, e)
		}
	}
	return out
}

// runSession meters one session of d against the host, ending it where the clock
// stands plus d, and leaves the clock there.
func (h *harness) runSession(sessionID, hostDeviceID string, d time.Duration) {
	h.t.Helper()
	h.startSession(sessionID, hostDeviceID, h.clock.Now().UnixMilli())
	h.clock.advance(d)
	stop := protocol.SessionStopReport{SessionID: sessionID, EndedAt: h.clock.Now().UnixMilli(),
		Reason: protocol.ByeUserEnded}
	if r := h.call("POST", protocol.PathInternalSessionStop, internalToken, "", stop); r.status != http.StatusNoContent {
		h.t.Fatalf("stop %s: %d %s", sessionID, r.status, r.body)
	}
}

// A session that outruns the credit behind it settles for what is there and stops.
// Before the floor existed a 30-minute trial session simply drove the balance
// negative and kept hosting, and the next top-up paid off the debt instead of
// buying hours.
func TestABalanceNeverGoesBelowZeroAndTheSessionIsClosed(t *testing.T) {
	h := newHarness(t)
	const email = "floor@example.com"
	h.link(email, newDevice(t), "SERIAL-FLOOR")
	// The same hardware a second time grants no trial, so this device's whole
	// balance is the one cent the test puts there.
	host := h.link(email, newDevice(t), "SERIAL-FLOOR")
	spendDown(h, email)
	h.topUp(email, 1)

	h.runSession(strings.Repeat("1", 32), host.DeviceID, 30*time.Minute)

	if got := h.balance(email); got != 0 {
		t.Fatalf("balance after a 30-minute session on one cent = %d, want exactly 0", got)
	}
	charges := h.entriesOfType(email, protocol.LedgerSessionCharge)
	last := charges[len(charges)-1]
	if last.AmountCents != -1 || last.BalanceAfterCents != 0 {
		t.Fatalf("the clamped charge is %+v, want -1 leaving 0", last)
	}
	if status, reason := h.internalEntitlement(host.DeviceID); status != http.StatusPaymentRequired ||
		reason != protocol.EntitlementNoBalance {
		t.Fatalf("after the credit ran out: %d/%s, want 402/no_balance", status, reason)
	}
	if !closedFor(h, host.DeviceID) {
		t.Fatalf("the session was left running on a balance of zero; closes = %+v", h.closes.calls())
	}

	h.topUp(email, 500)
	if got := h.balance(email); got != 500 {
		t.Fatalf("balance after a $5 top-up = %d, want 500 and no debt carried into it", got)
	}
	if got := h.entitlementFor(host.DeviceToken).Status; got != protocol.StatusActive {
		t.Fatalf("status after the top-up = %s, want active", got)
	}
}

// 10 cents an hour is not a whole number of cents a minute. Without the carry,
// rounding each session up would make twenty short sessions cost many times one
// long session of the same wall-clock time.
func TestManyShortSessionsCostWhatOneLongSessionCosts(t *testing.T) {
	h := newHarness(t)
	const short, long = "short@example.com", "long@example.com"
	shortHost := h.link(short, newDevice(t), "SERIAL-SHORT")
	longHost := h.link(long, newDevice(t), "SERIAL-LONG")
	h.topUp(short, 500)
	h.topUp(long, 500)
	funded := int64(500 + policy.TrialGrantCents)

	for i := range 20 {
		h.runSession(fmt.Sprintf("%032x", i+1), shortHost.DeviceID, 90*time.Second)
	}
	h.runSession(strings.Repeat("9", 32), longHost.DeviceID, 30*time.Minute)

	shortCost, longCost := funded-h.balance(short), funded-h.balance(long)
	if diff := shortCost - longCost; diff < -1 || diff > 1 {
		t.Fatalf("twenty 90-second sessions cost %d cents and one 30-minute session %d; "+
			"they are 30 minutes either way and must agree to within the cent in the carry",
			shortCost, longCost)
	}
	if longCost != 5 {
		t.Fatalf("a 30-minute session cost %d cents, want 5 at %d an hour",
			longCost, policy.RateCentsPerHour)
	}
}

// One hour is the rate, read straight off the ledger.
func TestAnHourCostsTheRate(t *testing.T) {
	h := newHarness(t)
	const email = "hour@example.com"
	host := h.link(email, newDevice(t), "SERIAL-HOUR")
	h.topUp(email, 500)

	h.runSession(strings.Repeat("7", 32), host.DeviceID, time.Hour)

	charges := h.entriesOfType(email, protocol.LedgerSessionCharge)
	if len(charges) != 1 || charges[0].AmountCents != -policy.RateCentsPerHour {
		t.Fatalf("an hour billed %+v, want one entry of -%d", charges, policy.RateCentsPerHour)
	}
}

// The trial is credit with an expiry, not a calendar: it arrives as a ledger entry,
// it is spent by sessions, and the window closes by taking back only what no session
// spent.
func TestTheTrialIsCreditThatExpiresWithoutTouchingPaidCredit(t *testing.T) {
	h := newHarness(t)
	const email = "grant@example.com"
	granted := h.clock.Now()
	host := h.link(email, newDevice(t), "SERIAL-GRANT")

	ent := h.entitlementFor(host.DeviceToken)
	if ent.Status != protocol.StatusTrial {
		t.Fatalf("a fresh device reads %s, want trial", ent.Status)
	}
	if ent.BalanceCents == nil || *ent.BalanceCents != policy.TrialGrantCents {
		t.Fatalf("balanceCents = %v, want %d", ent.BalanceCents, policy.TrialGrantCents)
	}
	if ent.MinutesRemaining == nil || *ent.MinutesRemaining != 300 {
		t.Fatalf("minutesRemaining = %v, want the 300 the grant buys", ent.MinutesRemaining)
	}
	if ent.TrialEndsAt == nil || *ent.TrialEndsAt != granted.Add(policy.TrialLifetime).UnixMilli() {
		t.Fatalf("trialEndsAt = %v, want the grant plus %v", ent.TrialEndsAt, policy.TrialLifetime)
	}
	grants := h.entriesOfType(email, protocol.LedgerTrialGrant)
	if len(grants) != 1 || grants[0].AmountCents != policy.TrialGrantCents ||
		grants[0].Memo != "starting credits" {
		t.Fatalf("the grant entry is %+v", grants)
	}

	h.runSession(strings.Repeat("2", 32), host.DeviceID, 30*time.Minute)

	ent = h.entitlementFor(host.DeviceToken)
	if ent.Status != protocol.StatusTrial {
		t.Fatalf("a trial with grant left reads %s, want trial", ent.Status)
	}
	if *ent.BalanceCents != policy.TrialGrantCents-5 || *ent.MinutesRemaining != 270 {
		t.Fatalf("after 30 minutes: %d cents, %d minutes; want 45 and 270",
			*ent.BalanceCents, *ent.MinutesRemaining)
	}

	// Paid credit arrives, so the status is no longer a trial even inside the window.
	h.topUp(email, 500)
	if got := h.entitlementFor(host.DeviceToken).Status; got != protocol.StatusActive {
		t.Fatalf("a topped-up account inside the window reads %s, want active", got)
	}

	h.clock.advance(policy.TrialLifetime + time.Minute)
	ent = h.entitlementFor(host.DeviceToken)
	if got := h.balance(email); got != 500 {
		t.Fatalf("balance after the window closed = %d; expiry took %d cents of paid credit",
			got, 500-got)
	}
	if ent.Status != protocol.StatusActive {
		t.Fatalf("an account with paid credit reads %s after expiry, want active", ent.Status)
	}
	expiries := h.entriesOfType(email, protocol.LedgerTrialExpiry)
	if len(expiries) != 1 || expiries[0].AmountCents != -(policy.TrialGrantCents-5) {
		t.Fatalf("the expiry entry is %+v, want one of -45", expiries)
	}

	// Asking again settles nothing further: the window closes once.
	h.clock.advance(24 * time.Hour)
	h.entitlementFor(host.DeviceToken)
	if got := h.entriesOfType(email, protocol.LedgerTrialExpiry); len(got) != 1 {
		t.Fatalf("the window was clawed back %d times, want once", len(got))
	}
}

// With nothing bought, an expired grant leaves exactly zero — never a negative
// balance that a later top-up would silently pay off.
func TestAnUntouchedTrialExpiresToExactlyZero(t *testing.T) {
	h := newHarness(t)
	const email = "lapsed@example.com"
	host := h.link(email, newDevice(t), "SERIAL-LAPSED")

	h.clock.advance(policy.TrialLifetime + time.Minute)

	ent := h.entitlementFor(host.DeviceToken)
	if ent.Status != protocol.StatusExhausted {
		t.Fatalf("an expired trial reads %s, want exhausted", ent.Status)
	}
	if *ent.BalanceCents != 0 || *ent.MinutesRemaining != 0 {
		t.Fatalf("balance %d, minutes %d; want 0 and 0, never below",
			*ent.BalanceCents, *ent.MinutesRemaining)
	}
	if status, reason := h.internalEntitlement(host.DeviceID); status != http.StatusPaymentRequired ||
		reason != protocol.EntitlementTrialExpired {
		t.Fatalf("an expired trial: %d/%s, want 402/trial_expired", status, reason)
	}
	h.topUp(email, 500)
	if got := h.balance(email); got != 500 {
		t.Fatalf("a top-up after expiry = %d, want the full 500", got)
	}
}

// The floor is an invariant of the ledger, not a courtesy of the metering caller:
// any other debit that would breach it is refused outright.
func TestTheLedgerRefusesADebitThatWouldBreachZero(t *testing.T) {
	h := newHarness(t)
	const email = "refuse@example.com"
	h.link(email, newDevice(t), "SERIAL-REFUSE")
	account, err := h.db.AccountByEmail(email)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.db.Append(account.AccountID, protocol.LedgerAdjustment, -51,
		h.clock.Now().UnixMilli(), "", "", "too much"); err == nil {
		t.Fatal("a 51-cent debit against a 50-cent balance was accepted")
	}
	if got := h.balance(email); got != policy.TrialGrantCents {
		t.Fatalf("the refused debit moved the balance to %d", got)
	}
}

func closedFor(h *harness, deviceID string) bool {
	h.t.Helper()
	for _, c := range h.closes.calls() {
		if c.DeviceID == deviceID {
			return true
		}
	}
	return false
}

// spendDown empties whatever the links granted, so a test can state the balance it
// wants outright.
func spendDown(h *harness, email string) {
	h.t.Helper()
	account, err := h.db.AccountByEmail(email)
	if err != nil {
		h.t.Fatal(err)
	}
	balance, err := h.db.Balance(account.AccountID)
	if err != nil {
		h.t.Fatal(err)
	}
	if balance == 0 {
		return
	}
	if _, err := h.db.Append(account.AccountID, protocol.LedgerAdjustment, -balance,
		h.clock.Now().UnixMilli(), "", "", "test setup"); err != nil {
		h.t.Fatal(err)
	}
}
