package policy

import (
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
		{"trial", Facts{Known: true, TrialEndsAt: live}, protocol.StatusTrial, ""},
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
	got := Decide(Facts{Known: true, TrialEndsAt: TrialEndsAt(now)}, now)
	if got.Entitlement.TrialEndsAt == nil || *got.Entitlement.TrialEndsAt != now.Add(TrialDays*24*time.Hour).UnixMilli() {
		t.Fatalf("trialEndsAt = %v, want %d days from now", got.Entitlement.TrialEndsAt, TrialDays)
	}
	if got.Entitlement.BalanceCents != nil {
		t.Fatalf("a device with no account must not report a balance")
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

func TestASubMinuteSessionIsFreeAndLongerOnesRoundUp(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want int64
	}{
		{0, 0},
		{-time.Second, 0},
		{time.Millisecond, 0},
		{59 * time.Second, 0},
		{time.Minute - time.Millisecond, 0},
		{time.Minute, 1 * RateCentsPerMinute},
		{time.Minute + time.Millisecond, 2 * RateCentsPerMinute},
		{90 * time.Minute, 90 * RateCentsPerMinute},
	}
	for _, c := range cases {
		if got := ChargeCents(c.d); got != c.want {
			t.Errorf("ChargeCents(%v) = %d, want %d", c.d, got, c.want)
		}
	}
}
