// The quality ceiling the server states, and the clamp every client owes it
// (API.md §4.4, BETA.md §2.2).
package policy

import (
	"testing"
	"time"

	protocol "rcprotocol"
)

// The gate. A trial is capped to the middle tier because the grant it was given was
// priced at that tier's bitrate; if a trial can be stated the top tier, the trial
// costs four times what BETA.md §1.1 sized it for.
func TestATrialIsNeverStatedTheTopQualityTier(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	trial := Decide(Facts{
		Known: true, HasAccount: true,
		BalanceCents: TrialGrantCents, UnconsumedGrant: TrialGrantCents,
		TrialEndsAt: TrialEndsAt(now),
	}, now)

	if trial.Entitlement.Status != protocol.StatusTrial {
		t.Fatalf("status = %q, want trial", trial.Entitlement.Status)
	}
	if got := trial.Entitlement.Limits.MaxQuality; got != protocol.QualityAuto {
		t.Fatalf("a trial's maxQuality = %q, want %q", got, protocol.QualityAuto)
	}
	if got := protocol.ClampQuality(protocol.QualitySharp, trial.Entitlement.Limits.MaxQuality); got != protocol.QualityAuto {
		t.Fatalf("a trial host asked for %q and was permitted %q; the gate is open",
			protocol.QualitySharp, got)
	}
}

// Paid credit buys the whole ladder: a paid hour is charged whatever bitrate and
// whatever route it takes, and egress alone cannot break the rate (PHASE5.md §3.3).
func TestPaidCreditIsStatedTheTopQualityTier(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	active := Decide(Facts{Known: true, HasAccount: true, BalanceCents: 500}, now)

	if active.Entitlement.Status != protocol.StatusActive {
		t.Fatalf("status = %q, want active", active.Entitlement.Status)
	}
	if got := active.Entitlement.Limits.MaxQuality; got != protocol.QualitySharp {
		t.Fatalf("a paid account's maxQuality = %q, want %q", got, protocol.QualitySharp)
	}
}

// Every answer carries a ceiling, including the refusals: a client that reads one
// must never find the field empty and fall back to its own idea of a default.
func TestEveryDecisionStatesACeilingAndNoneOfThemFailsOpen(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	for name, facts := range map[string]Facts{
		"unknown":   {},
		"unlinked":  {Known: true, Unlinked: true},
		"suspended": {Known: true, HasAccount: true, Suspended: true, BalanceCents: 500},
		"exhausted": {Known: true, HasAccount: true},
		"busy":      {Known: true, HasAccount: true, BalanceCents: 500, ActivePairs: MaxActivePairs},
	} {
		got := Decide(facts, now).Entitlement.Limits.MaxQuality
		if got == "" {
			t.Fatalf("%s stated no maxQuality", name)
		}
		if name != "busy" && got != protocol.QualityAuto {
			t.Fatalf("%s stated %q; an answer that cannot host must fail closed", name, got)
		}
	}
}

// An unrecognised ceiling, and an unrecognised request, both resolve to the middle
// tier. A value neither end understands must not buy the best one.
func TestAnUnknownQualityValueNeverBuysTheTopTier(t *testing.T) {
	for name, got := range map[string]string{
		"unknown ceiling": protocol.ClampQuality(protocol.QualitySharp, "platinum"),
		"empty ceiling":   protocol.ClampQuality(protocol.QualitySharp, ""),
		"unknown request": protocol.ClampQuality("platinum", protocol.QualitySharp),
	} {
		if got != protocol.QualityAuto {
			t.Fatalf("%s resolved to %q, want %q", name, got, protocol.QualityAuto)
		}
	}
}

// The clamp only ever lowers. A ceiling above the request does not raise it.
func TestTheClampNeverRaisesWhatWasAskedFor(t *testing.T) {
	for _, requested := range protocol.QualityModes {
		for _, ceiling := range protocol.QualityModes {
			got := protocol.ClampQuality(requested, ceiling)
			gotRank, _ := protocol.QualityRank(got)
			requestedRank, _ := protocol.QualityRank(requested)
			ceilingRank, _ := protocol.QualityRank(ceiling)
			if gotRank > requestedRank || gotRank > ceilingRank {
				t.Fatalf("requested %q under ceiling %q gave %q", requested, ceiling, got)
			}
		}
	}
}
