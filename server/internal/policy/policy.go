// Package policy is the single place where SkipperDesk decides what an account
// may do: trial grant, entitlement status, concurrency and what a session costs.
// SCOPE.md §7 tunes these numbers in Phase 6; nothing outside this file encodes them.
package policy

import (
	"math"
	"time"

	protocol "rcprotocol"
)

const (
	TrialDays          = 7
	RateCentsPerMinute = 1
	MaxActivePairs     = protocol.MaxActivePairs
	MinBalanceCents    = 1
	DefaultTier        = protocol.TierBase
	RefreshAfterSec    = protocol.EntitlementRefreshSec
	MinGiftCents       = protocol.MinGiftAmountCents
	GiftLifetime       = protocol.GiftTTLSec * time.Second
	TrialLifetime      = TrialDays * 24 * time.Hour
)

// Facts is everything the policy is allowed to look at.
type Facts struct {
	Known        bool
	Unlinked     bool
	Suspended    bool
	HasAccount   bool
	TrialEndsAt  int64
	BalanceCents int64
	ActivePairs  int
}

// Decision carries the §4.1 answer and, when the answer is a refusal the client
// must be told about by reason rather than by status, the §4.3 reason.
type Decision struct {
	Entitlement protocol.Entitlement
	Reason      string
}

func TrialEndsAt(now time.Time) int64 { return now.Add(TrialLifetime).UnixMilli() }

// GrantsTrial answers the only question hardwareHash exists for (API.md §3.2).
func GrantsTrial(pubkeySeen, hardwareSeen bool) bool { return !pubkeySeen && !hardwareSeen }

// ChargeCents rounds a session up to the next whole minute.
func ChargeCents(d time.Duration) int64 {
	if d <= 0 {
		return 0
	}
	minutes := math.Ceil(d.Minutes())
	return int64(minutes) * RateCentsPerMinute
}

func Decide(f Facts, now time.Time) Decision {
	ent := protocol.Entitlement{
		Tier:            DefaultTier,
		Concurrency:     protocol.Concurrency{MaxActivePairs: MaxActivePairs},
		RefreshAfterSec: RefreshAfterSec,
	}
	if !f.Known || f.Unlinked {
		ent.Status = protocol.StatusUnlinked
		return Decision{Entitlement: ent, Reason: protocol.EntitlementUnlinked}
	}
	if f.Suspended {
		ent.Status = protocol.StatusExhausted
		return Decision{Entitlement: ent, Reason: protocol.EntitlementSuspended}
	}
	if f.HasAccount {
		balance := f.BalanceCents
		ent.BalanceCents = &balance
	}
	switch {
	case f.BalanceCents >= MinBalanceCents:
		ent.Status = protocol.StatusActive
	case f.TrialEndsAt > now.UnixMilli():
		ent.Status = protocol.StatusTrial
		trialEnds := f.TrialEndsAt
		ent.TrialEndsAt = &trialEnds
	default:
		ent.Status = protocol.StatusExhausted
		reason := protocol.EntitlementTrialExpired
		if f.HasAccount && f.TrialEndsAt != 0 {
			reason = protocol.EntitlementNoBalance
		}
		return Decision{Entitlement: ent, Reason: reason}
	}
	if f.ActivePairs >= MaxActivePairs {
		return Decision{Entitlement: ent, Reason: protocol.EntitlementConcurrency}
	}
	return Decision{Entitlement: ent}
}
