package policy

import (
	"testing"
	"time"

	protocol "rcprotocol"
)

// The device inputs are both client-chosen, so the grants the account already holds
// is the only one of the three that bounds anything (review5 H4).
func TestTrialIsCappedPerAccountAndWithheldByTheDeviceRules(t *testing.T) {
	cases := []struct {
		pubkeySeen, hardwareSeen bool
		grantsHeld               int
		want                     bool
	}{
		{false, false, 0, true},
		{true, false, 0, false},
		{false, true, 0, false},
		{true, true, 0, false},
		{false, false, MaxTrialGrantsPerMailbox, false},
		{false, false, MaxTrialGrantsPerMailbox + 5, false},
	}
	for _, c := range cases {
		if got := GrantsTrial(c.pubkeySeen, c.hardwareSeen, c.grantsHeld); got != c.want {
			t.Errorf("GrantsTrial(pubkey=%v, hardware=%v, held=%d) = %v, want %v",
				c.pubkeySeen, c.hardwareSeen, c.grantsHeld, got, c.want)
		}
	}
}

func TestDecideStatuses(t *testing.T) {
	now := time.UnixMilli(1_800_000_000_000)
	live := TrialEndsAt(now)
	ended := now.Add(-time.Minute).UnixMilli()
	cases := []struct {
		name       string
		facts      Facts
		wantStatus string
		wantReason string
	}{
		{"unknown", Facts{}, protocol.StatusUnlinked, protocol.EntitlementUnlinked},
		{"unlinked", Facts{Known: true, Unlinked: true, TrialEndsAt: live}, protocol.StatusUnlinked, protocol.EntitlementUnlinked},
		{"a live grant window and the whole balance still grant", Facts{Known: true, HasAccount: true,
			BalanceCents: TrialGrantCents, UnconsumedGrant: TrialGrantCents, TrialEndsAt: live},
			protocol.StatusTrial, ""},
		{"a live window whose grant is spent down but not out", Facts{Known: true, HasAccount: true,
			BalanceCents: 3, UnconsumedGrant: 3, TrialEndsAt: live}, protocol.StatusTrial, ""},
		{"a live window plus paid credit reads active, not trial", Facts{Known: true, HasAccount: true,
			BalanceCents: 550, UnconsumedGrant: TrialGrantCents, TrialEndsAt: live},
			protocol.StatusActive, ""},
		{"a window with no grant behind it is not a trial", Facts{Known: true, TrialEndsAt: live},
			protocol.StatusExhausted, protocol.EntitlementTrialExpired},
		{"active", Facts{Known: true, HasAccount: true, BalanceCents: 1, TrialEndsAt: ended}, protocol.StatusActive, ""},
		{"trial over, no account", Facts{Known: true, TrialEndsAt: ended}, protocol.StatusExhausted, protocol.EntitlementTrialExpired},
		{"trial over, empty balance", Facts{Known: true, HasAccount: true, TrialEndsAt: ended}, protocol.StatusExhausted, protocol.EntitlementTrialExpired},
		{"never had a trial", Facts{Known: true, HasAccount: true}, protocol.StatusExhausted, protocol.EntitlementNoBalance},
		{"paid and spent it is not a trial ending", Facts{Known: true, HasAccount: true,
			TrialEndsAt: ended, HeldPaidCredit: true},
			protocol.StatusExhausted, protocol.EntitlementNoBalance},
		{"paid, spent it, and still inside the grant window", Facts{Known: true, HasAccount: true,
			TrialEndsAt: live, HeldPaidCredit: true},
			protocol.StatusExhausted, protocol.EntitlementNoBalance},
		{"suspended", Facts{Known: true, HasAccount: true, Suspended: true, BalanceCents: 500}, protocol.StatusExhausted, protocol.EntitlementSuspended},
	}
	for _, c := range cases {
		got := Decide(c.facts, now)
		if got.Entitlement.Status != c.wantStatus || got.Reason != c.wantReason {
			t.Errorf("%s: got %s/%q, want %s/%q", c.name, got.Entitlement.Status, got.Reason, c.wantStatus, c.wantReason)
		}
		if got.Entitlement.Concurrency.MaxActivePairs != MaxActivePairs || got.Entitlement.RefreshAfterSec != RefreshAfterSec {
			t.Errorf("%s: concurrency/refresh not stated: %+v", c.name, got.Entitlement)
		}
	}
}

func TestDecideTrialCarriesItsEnd(t *testing.T) {
	now := time.UnixMilli(1_800_000_000_000)
	got := Decide(Facts{Known: true, HasAccount: true, BalanceCents: TrialGrantCents,
		UnconsumedGrant: TrialGrantCents, TrialEndsAt: TrialEndsAt(now)}, now)
	if got.Entitlement.TrialEndsAt == nil || *got.Entitlement.TrialEndsAt != now.Add(TrialDays*24*time.Hour).UnixMilli() {
		t.Fatalf("trialEndsAt = %v, want %d days from now", got.Entitlement.TrialEndsAt, TrialDays)
	}
	if got.Entitlement.MinutesRemaining == nil || *got.Entitlement.MinutesRemaining != 300 {
		t.Fatalf("minutesRemaining = %v, want the 5 hours the grant buys", got.Entitlement.MinutesRemaining)
	}
	bare := Decide(Facts{Known: true, TrialEndsAt: TrialEndsAt(now)}, now)
	if bare.Entitlement.BalanceCents != nil || bare.Entitlement.MinutesRemaining != nil {
		t.Fatalf("a device with no account must not report a balance or an hours figure")
	}
}

// The grant is stated in cents and read out in hours, so the two must agree: a
// trial that does not buy the five hours §1.1 priced is a different product.
func TestTheTrialGrantBuysFiveHours(t *testing.T) {
	if got := MinutesRemaining(TrialGrantCents); got != 5*60 {
		t.Fatalf("the %d-cent grant buys %d minutes, want 300", TrialGrantCents, got)
	}
	if got := MinutesRemaining(500); got != 50*60 {
		t.Fatalf("a $5 top-up buys %d minutes, want 50 hours", got)
	}
	if got := MinutesRemaining(0); got != 0 {
		t.Fatalf("an empty balance buys %d minutes", got)
	}
	if got := MinutesRemaining(-19); got != 0 {
		t.Fatalf("a negative balance must never read as %d minutes of credit", got)
	}
}

// Expiry takes back grant nobody spent and never a cent of paid credit.
func TestExpiredGrantClawbackNeverReachesPaidCredit(t *testing.T) {
	cases := []struct{ grant, balance, want int64 }{
		{50, 50, 50},
		{50, 550, 50},
		{20, 20, 20},
		{0, 500, 0},
		{50, 0, 0},
		{50, 30, 30},
	}
	for _, c := range cases {
		if got := ExpiredGrantClawback(c.grant, c.balance); got != c.want {
			t.Errorf("ExpiredGrantClawback(grant=%d, balance=%d) = %d, want %d",
				c.grant, c.balance, got, c.want)
		}
	}
}

func TestConcurrencyRefusesASecondPair(t *testing.T) {
	now := time.UnixMilli(1_800_000_000_000)
	free := Decide(Facts{Known: true, HasAccount: true, BalanceCents: 100}, now)
	if free.Reason != "" {
		t.Fatalf("no open pair: reason %q, want none", free.Reason)
	}
	busy := Decide(Facts{Known: true, HasAccount: true, BalanceCents: 100, ActivePairs: MaxActivePairs}, now)
	if busy.Reason != protocol.EntitlementConcurrency || busy.Entitlement.Status != protocol.StatusActive {
		t.Fatalf("open pair: got %s/%q, want active/concurrency", busy.Entitlement.Status, busy.Reason)
	}
}

// A session too short to be worth a cent still bills nothing, so one short session
// costs an honest user exactly what it costs today.
func TestASessionTooShortToBeWorthACentBillsNothing(t *testing.T) {
	for _, d := range []time.Duration{0, -time.Second, time.Millisecond, 59 * time.Second,
		time.Minute - time.Millisecond, 5 * time.Minute} {
		if cents, _ := Charge(d, 0); cents != 0 {
			t.Errorf("Charge(%v, 0) = %d cents, want nothing billed", d, cents)
		}
	}
	if cents, carry := Charge(0, 41); cents != 0 || carry != 41 {
		t.Errorf("Charge(0, 41) = %d cents, carry %d; a session of no length owes nothing", cents, carry)
	}
}

// The hole C1 found: the free window was a property of each session, so repeating a
// 59-second session bought relay for nothing however often it was repeated. The
// un-charged time now lands on the carry, so the hundredth repeat costs what the
// hundredth minute of one long session costs.
func TestRepeatedShortSessionsCostWhatTheirTotalLengthCosts(t *testing.T) {
	const n, each = 100, 59 * time.Second

	var repeated, carry int64
	for range n {
		var cents int64
		cents, carry = Charge(each, carry)
		repeated += cents
	}
	oneLong, _ := Charge(n*each, 0)

	if repeated != oneLong {
		t.Fatalf("%d sessions of %v cost %d cents, one session of %v costs %d; "+
			"the short ones must not be cheaper", n, each, repeated, n*each, oneLong)
	}
	if repeated == 0 {
		t.Fatalf("%d sessions of %v were free, which is the whole of C1", n, each)
	}
}

func TestAnHourCostsTheHourlyRateExactly(t *testing.T) {
	cents, carry := Charge(time.Hour, 0)
	if cents != RateCentsPerHour || carry != 0 {
		t.Fatalf("one hour = %d cents, carry %d; want %d and nothing left over",
			cents, carry, RateCentsPerHour)
	}
	if cents, carry = Charge(3*time.Hour, 0); cents != 3*RateCentsPerHour || carry != 0 {
		t.Fatalf("three hours = %d cents, carry %d", cents, carry)
	}
}

// The rate is not a whole number of cents per minute, so rounding each session on its
// own would make short sessions far dearer than long ones. The carry is what stops
// that, and this is the test that holds it: many short sessions and one long session
// of the same wall-clock time cost the same to within the cent still in the carry.
func TestManyShortSessionsCostTheSameAsOneLongOne(t *testing.T) {
	long, _ := Charge(30*time.Minute, 0)

	var short, carry int64
	for range 20 {
		var cents int64
		cents, carry = Charge(90*time.Second, carry)
		short += cents
	}

	if diff := short - long; diff < -1 || diff > 1 {
		t.Fatalf("twenty 90-second sessions cost %d cents, one 30-minute session %d; "+
			"the difference is %d cents, want no more than 1", short, long, diff)
	}
	if long != 5 {
		t.Fatalf("one 30-minute session = %d cents, want 5 at %d cents an hour", long, RateCentsPerHour)
	}
}

// Nothing is lost or invented between sessions: over any run of sessions the cents
// billed plus the carry still held equals what the seconds were worth.
func TestTheCarryNeitherLosesNorInventsMoney(t *testing.T) {
	durations := []time.Duration{
		90 * time.Second, time.Minute, 7 * time.Minute, 61 * time.Second,
		time.Hour, 23 * time.Minute, 30 * time.Second, 119 * time.Second, time.Millisecond,
	}
	var billed, carry, seconds int64
	for _, d := range durations {
		var cents int64
		cents, carry = Charge(d, carry)
		billed += cents
		seconds += int64(d / time.Second)
	}
	if got, want := billed*SecondsPerHour+carry, seconds*RateCentsPerHour; got != want {
		t.Fatalf("billed %d cents and hold a carry of %d (%d units) against %d seconds "+
			"worth %d units", billed, carry, got, seconds, want)
	}
	if carry < 0 || carry >= SecondsPerHour {
		t.Fatalf("the carry is %d; it must stay inside one cent", carry)
	}
}
