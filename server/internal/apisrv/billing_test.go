// Billing acceptance: the balance floor, the hourly rate's carry, and the trial as
// credit (BETA.md §1.2, §1.3, §3.1). These run the real handlers over the real
// ledger, because the bug they exist to prevent is arithmetic a unit test of
// policy alone cannot see.
package apisrv

import (
	"database/sql"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"rc-signal/internal/apidb"
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
	// The account did get starting credits and they ran out, so the reason is
	// trial_expired rather than no_balance (API.md §4.3). The grant's window is the
	// account's, so a second device on it reports the window the first one holds.
	if status, reason := h.internalEntitlement(host.DeviceID); status != http.StatusPaymentRequired ||
		reason != protocol.EntitlementTrialExpired {
		t.Fatalf("after the credit ran out: %d/%s, want 402/trial_expired", status, reason)
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

// review5 C1: the free window used to be a property of each session, so a host that
// tore every session down at 59 seconds hosted for nothing at any balance, for ever.
// The connect budget allows 60 sessions an hour, which covered 98% of the clock. The
// un-charged time is an account allowance now, so sixty reconnects cost what the hour
// they cover costs — and the account runs out like any other.
func TestReconnectingBelowTheFreeWindowCannotHostForNothing(t *testing.T) {
	h := newHarness(t)
	const farm, honest = "farm@example.com", "honest@example.com"
	farmHost := h.link(farm, newDevice(t), "SERIAL-FARM")
	honestHost := h.link(honest, newDevice(t), "SERIAL-HONEST")
	h.topUp(farm, 500)
	h.topUp(honest, 500)
	funded := int64(500 + policy.TrialGrantCents)

	// Sixty 59-second sessions: 59 minutes of hosting in 60 reconnects.
	for i := range 60 {
		h.runSession(fmt.Sprintf("%032x", 0xf00+i), farmHost.DeviceID, 59*time.Second)
	}
	h.runSession(strings.Repeat("a", 32), honestHost.DeviceID, 59*time.Minute)

	farmed, straight := funded-h.balance(farm), funded-h.balance(honest)
	if farmed == 0 {
		t.Fatalf("sixty 59-second sessions cost nothing: %d minutes of relay were free", 59)
	}
	if diff := farmed - straight; diff < -1 || diff > 1 {
		t.Fatalf("sixty 59-second sessions cost %d cents and one 59-minute session %d; "+
			"they are 59 minutes either way and must agree to within the cent in the carry",
			farmed, straight)
	}

	// One short session on its own still bills an honest user nothing.
	solo := h.link("solo@example.com", newDevice(t), "SERIAL-SOLO")
	h.topUp("solo@example.com", 500)
	h.runSession(strings.Repeat("b", 32), solo.DeviceID, 30*time.Second)
	if got := h.balance("solo@example.com"); got != 500+policy.TrialGrantCents {
		t.Fatalf("one 30-second session billed %d cents", 500+policy.TrialGrantCents-got)
	}
	if got := h.entriesOfType("solo@example.com", protocol.LedgerSessionCharge); len(got) != 0 {
		t.Fatalf("one 30-second session wrote %d charge entries, want none", len(got))
	}
}

// API.md §5.2 promises one session_charge per session, and the carry must not turn
// that into several or none where a cent was owed.
func TestASettledSessionWritesAtMostOneChargeEntry(t *testing.T) {
	h := newHarness(t)
	const email = "oneentry@example.com"
	host := h.link(email, newDevice(t), "SERIAL-ONE-ENTRY")
	h.topUp(email, 500)

	for i := range 12 {
		h.runSession(fmt.Sprintf("%032x", 0xe00+i), host.DeviceID, 10*time.Minute)
	}

	charges := h.entriesOfType(email, protocol.LedgerSessionCharge)
	if len(charges) != 12 {
		t.Fatalf("twelve 10-minute sessions wrote %d charge entries, want one each", len(charges))
	}
	bySession := map[string]int{}
	for _, c := range charges {
		bySession[c.SessionID]++
	}
	for id, n := range bySession {
		if n != 1 {
			t.Fatalf("session %s has %d charge entries, want exactly one", id, n)
		}
	}
	if got := h.balance(email); got != 500+policy.TrialGrantCents-20 {
		t.Fatalf("two hours of hosting cost %d cents, want 20", 500+policy.TrialGrantCents-got)
	}
}

// The carry changed unit when the free window became an allowance, so the value the
// live account is holding has to cross exactly: both units divide a cent, and a
// migration that lost or invented a fraction of one would be a silent adjustment.
func TestTheCarryCrossesToTheNewUnitExactly(t *testing.T) {
	h := newHarness(t)
	const email = "carry@example.com"
	host := h.link(email, newDevice(t), "SERIAL-CARRY")
	h.topUp(email, 500)
	account, err := h.db.AccountByEmail(email)
	if err != nil {
		t.Fatal(err)
	}

	// 59 sixtieths of a cent is the most the old scheme could hold: a cent all but
	// owed. In the new unit that is 59 * 60 = 3540, so one more minute of hosting
	// crosses the cent and bills it.
	h.rawExec(`ALTER TABLE accounts DROP COLUMN unbilled_units`)
	h.rawExec(`ALTER TABLE accounts ADD COLUMN billing_carry INTEGER NOT NULL DEFAULT 0`)
	h.rawExec(`UPDATE accounts SET billing_carry=59 WHERE account_id=?`, account.AccountID)
	h.reopen()

	if got := h.rawInt(`SELECT unbilled_units FROM accounts WHERE account_id=?`, account.AccountID); got != 59*60 {
		t.Fatalf("a carry of 59 sixtieths crossed as %d units, want %d", got, 59*60)
	}

	h.runSession(strings.Repeat("c", 32), host.DeviceID, time.Minute)
	if got := h.balance(email); got != 500+policy.TrialGrantCents-1 {
		t.Fatalf("the minute that crossed the carried cent billed %d, want 1",
			500+policy.TrialGrantCents-got)
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

// rawExec writes state the current code refuses to produce. Its callers are the
// migration tests, which have to recreate the shape a migration exists to meet.
func (h *harness) rawExec(query string, args ...any) {
	h.t.Helper()
	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		h.t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(query, args...); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) rawInt(query string, args ...any) int64 {
	h.t.Helper()
	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		h.t.Fatal(err)
	}
	defer db.Close()
	var out int64
	if err := db.QueryRow(query, args...).Scan(&out); err != nil {
		h.t.Fatal(err)
	}
	return out
}

// reopen runs what a restart runs: the schema and every migration in it.
func (h *harness) reopen() {
	h.t.Helper()
	db, err := apidb.Open(h.dbPath, filepath.Join(filepath.Dir(h.dbPath), "api-claims.db"))
	if err != nil {
		h.t.Fatal(err)
	}
	db.Close()
}

// The one account that exists signed up under the calendar trial and, with no floor,
// could be carrying a negative balance. The migration is what it meets on the first
// restart after this change.
func TestTheMigrationGivesAnOldTrialItsCreditAndForgivesTheDebt(t *testing.T) {
	h := newHarness(t)
	const email = "owner@example.com"
	host := h.link(email, newDevice(t), "SERIAL-OWNER")
	account, err := h.db.AccountByEmail(email)
	if err != nil {
		t.Fatal(err)
	}

	// Rewind to what the old scheme left behind: a calendar window, no grant on the
	// ledger, and the negative balance the missing floor allowed.
	h.rawExec(`DELETE FROM ledger WHERE account_id=?`, account.AccountID)
	h.rawExec(`INSERT INTO ledger (entry_id, account_id, type, amount_cents,
 balance_after_cents, created_at, session_id, gift_id, memo) VALUES (?,?,?,?,?,?,'','','')`,
		"led_old", account.AccountID, protocol.LedgerSessionCharge, -1900, -1900,
		h.clock.Now().UnixMilli())
	h.rawExec(`UPDATE devices SET trial_ends_at=? WHERE device_id=?`,
		h.clock.Now().Add(3*24*time.Hour).UnixMilli(), host.DeviceID)
	if got := h.balance(email); got != -1900 {
		t.Fatalf("the old balance is %d, want the -1900 the test set up", got)
	}

	now := h.clock.Now().UnixMilli()
	corrected, granted, err := h.db.MigrateTrialsToCredit(policy.TrialGrantCents,
		policy.TrialLifetime.Milliseconds(), now)
	if err != nil {
		t.Fatal(err)
	}
	if corrected != 1 || granted != 1 {
		t.Fatalf("the migration corrected %d balances and wrote %d grants, want 1 and 1",
			corrected, granted)
	}

	ent := h.entitlementFor(host.DeviceToken)
	if ent.Status != protocol.StatusTrial {
		t.Fatalf("after the migration the owner reads %s, want trial", ent.Status)
	}
	if *ent.BalanceCents != policy.TrialGrantCents || *ent.MinutesRemaining != 300 {
		t.Fatalf("after the migration: %d cents, %d minutes; want 50 and 300",
			*ent.BalanceCents, *ent.MinutesRemaining)
	}
	if *ent.TrialEndsAt != now+policy.TrialLifetime.Milliseconds() {
		t.Fatalf("the window ends at %d, want the migration plus %v",
			*ent.TrialEndsAt, policy.TrialLifetime)
	}

	// Running it again is a no-op, which is what makes a restart safe.
	corrected, granted, err = h.db.MigrateTrialsToCredit(policy.TrialGrantCents,
		policy.TrialLifetime.Milliseconds(), now)
	if err != nil || corrected != 0 || granted != 0 {
		t.Fatalf("a second run corrected %d and granted %d (err=%v), want nothing",
			corrected, granted, err)
	}
}
