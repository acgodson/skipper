package policy

import (
	"math"
	"testing"
	"time"

	protocol "rcprotocol"
)

func TestTrialIsKeyedByDeviceAndHardware(t *testing.T) {
	cases := []struct {
		pubkeySeen, hardwareSeen, want bool
	}{
		{false, false, true},
		{true, false, false},
		{false, true, false},
		{true, true, false},
	}
	for _, c := range cases {
		if got := GrantsTrial(c.pubkeySeen, c.hardwareSeen); got != c.want {
			t.Errorf("GrantsTrial(pubkey=%v, hardware=%v) = %v, want %v", c.pubkeySeen, c.hardwareSeen, got, c.want)
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

func TestASubMinuteSessionIsFreeAndNeverTouchesTheCarry(t *testing.T) {
	for _, d := range []time.Duration{0, -time.Second, time.Millisecond, 59 * time.Second,
		time.Minute - time.Millisecond} {
		cents, carry := Charge(d, 41)
		if cents != 0 || carry != 41 {
			t.Errorf("Charge(%v, 41) = %d cents, carry %d; want free and the carry untouched",
				d, cents, carry)
		}
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

	// Without the carry each 90-second session would round to a whole cent of its own.
	perSessionRounding := int64(0)
	for range 20 {
		cents, _ := Charge(90*time.Second, 0)
		perSessionRounding += cents
	}
	if perSessionRounding != 0 || short <= perSessionRounding {
		t.Fatalf("the carry is what makes the short sessions cost %d rather than %d",
			short, perSessionRounding)
	}
}

// Nothing is lost or invented between sessions: over any run of sessions the cents
// billed plus the carry still held equals the cents the minutes were worth.
func TestTheCarryNeitherLosesNorInventsMoney(t *testing.T) {
	durations := []time.Duration{
		90 * time.Second, time.Minute, 7 * time.Minute, 61 * time.Second,
		time.Hour, 23 * time.Minute, 30 * time.Second, 119 * time.Second,
	}
	var billed, carry, minutes int64
	for _, d := range durations {
		var cents int64
		cents, carry = Charge(d, carry)
		billed += cents
		if d >= FreeSessionLength {
			minutes += int64(math.Ceil(d.Minutes()))
		}
	}
	if got, want := billed*MinutesPerHour+carry, minutes*RateCentsPerHour; got != want {
		t.Fatalf("billed %d cents and hold a carry of %d (%d sixtieths) against %d minutes "+
			"worth %d sixtieths", billed, carry, got, minutes, want)
	}
	if carry < 0 || carry >= MinutesPerHour {
		t.Fatalf("the carry is %d; it must stay inside one cent", carry)
	}
}
