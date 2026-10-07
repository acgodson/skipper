// Package policy is the single place where SkipperDesk decides what an account
// may do: trial grant, entitlement status, concurrency and what a session costs.
// SCOPE.md §7 tunes these numbers in Phase 6; nothing outside this file encodes them.
package policy

import (
	"time"

	protocol "rcprotocol"
)

const (
	RateCentsPerHour = 10
	MinutesPerHour   = 60
	SecondsPerHour   = 3600
	TrialGrantCents  = 50
	TrialDays        = 14
	MaxActivePairs   = protocol.MaxActivePairs
	MinBalanceCents  = 1
	DefaultTier      = protocol.TierBase
	RefreshAfterSec  = protocol.EntitlementRefreshSec
	MinGiftCents     = protocol.MinGiftAmountCents
	GiftLifetime     = protocol.GiftTTLSec * time.Second
	TrialLifetime    = TrialDays * 24 * time.Hour

	// MaxTrialGrantsPerMailbox bounds what one verified mailbox is worth to a trial
	// farm: the grant cannot be keyed on anything the client asserts, so it is keyed
	// on the one durable fact there is. The device rules only ever withhold further.
	MaxTrialGrantsPerMailbox = 1

	// TrialMaxQuality is the ceiling a trial host may be configured to. It is the
	// middle tier because the trial's whole worst case is priced off that tier's
	// bitrate: TrialGrantCents buys TrialGrantCents/RateCentsPerHour hours, and those
	// hours are affordable only at the `auto` ceiling (BETA.md §1.1, §2.3). Letting a
	// trial ask for `sharp` would multiply its worst case by four against a grant
	// already sized and granted.
	TrialMaxQuality = protocol.QualityAuto

	// PaidMaxQuality is the top of the ladder. A paid hour is charged whatever route
	// it takes, and at RateCentsPerHour egress alone cannot break it (PHASE5.md §3.3).
	PaidMaxQuality = protocol.QualitySharp
)

// MaxQuality is the ceiling the server states for a status (API.md §4.4). Everything
// that cannot host is given the trial ceiling rather than the paid one: the answer is
// moot while hosting is refused, and if it is ever read it must fail closed.
func MaxQuality(status string) string {
	if status == protocol.StatusActive {
		return PaidMaxQuality
	}
	return TrialMaxQuality
}

// Facts is everything the policy is allowed to look at.
type Facts struct {
	Known           bool
	Unlinked        bool
	Suspended       bool
	HasAccount      bool
	TrialEndsAt     int64
	BalanceCents    int64
	UnconsumedGrant int64
	ActivePairs     int
}

// Decision carries the §4.1 answer and, when the answer is a refusal the client
// must be told about by reason rather than by status, the §4.3 reason.
type Decision struct {
	Entitlement protocol.Entitlement
	Reason      string
}

func TrialEndsAt(now time.Time) int64 { return now.Add(TrialLifetime).UnixMilli() }

// GrantsTrial answers the only question hardwareHash exists for (API.md §3.2).
//
// Both device inputs are client-chosen: a stranger generates a fresh keypair and
// sends any hardwareId they like, so neither can be made trustworthy and this
// deliberately does not pretend otherwise (review5 H4). What bounds the damage is
// grantsHeld, the grants already written against this verified mailbox, which is
// server-side fact. The device rules are kept: they only ever withhold further.
func GrantsTrial(pubkeySeen, hardwareSeen bool, grantsHeld int) bool {
	return !pubkeySeen && !hardwareSeen && grantsHeld < MaxTrialGrantsPerMailbox
}

// ExpiredGrantClawback is the one adjustment that closes a grant window. It takes
// only the part of the grant no session consumed, and never more than the balance,
// so credit the user paid for survives the expiry (BETA.md §1.3).
func ExpiredGrantClawback(unconsumedGrant, balance int64) int64 {
	return max(0, min(unconsumedGrant, balance))
}

// MinutesRemaining is the whole minutes of hosting a balance still buys (API.md §4.1).
// The client must never divide a balance by a rate itself (API.md §4.2).
func MinutesRemaining(balanceCents int64) int {
	if balanceCents <= 0 {
		return 0
	}
	return int(balanceCents * MinutesPerHour / RateCentsPerHour)
}

// Charge settles one session against the account's carry.
//
// The rate is per hour and a session is not a whole number of hours, so cost is held
// in units of one second at the hourly rate: a second of session is worth
// RateCentsPerHour units and one cent is SecondsPerHour of them. Whole cents are
// billed and the remainder stays on the account as carry. The unit divides the rate
// exactly whatever the rate is, so nothing is rounded away and N sessions cost what
// one session of their total length costs, to within the cent sitting in the carry.
//
// The sub-cent part of a session is therefore an account-level allowance, not a
// per-session gift: a session too short to be worth a cent bills nothing, but its
// time is still owed, so repeating it cannot buy relay for free. A free window that
// was a property of each session let sixty reconnects an hour cover the clock at no
// cost at any balance (review5 C1).
//
// Part-seconds are dropped, which is the one rounding here and is in the account's
// favour by under a second a session.
func Charge(d time.Duration, carry int64) (cents, newCarry int64) {
	units := carry + max(0, int64(d/time.Second))*RateCentsPerHour
	return units / SecondsPerHour, units % SecondsPerHour
}

func Decide(f Facts, now time.Time) Decision {
	ent := protocol.Entitlement{
		Tier:            DefaultTier,
		Concurrency:     protocol.Concurrency{MaxActivePairs: MaxActivePairs},
		RefreshAfterSec: RefreshAfterSec,
	}
	if !f.Known || f.Unlinked {
		ent.Status = protocol.StatusUnlinked
		return decision(ent, protocol.EntitlementUnlinked)
	}
	if f.Suspended {
		ent.Status = protocol.StatusExhausted
		return decision(ent, protocol.EntitlementSuspended)
	}
	if f.HasAccount {
		balance := f.BalanceCents
		minutes := MinutesRemaining(balance)
		ent.BalanceCents = &balance
		ent.MinutesRemaining = &minutes
	}
	switch {
	case f.BalanceCents >= MinBalanceCents && f.TrialEndsAt > now.UnixMilli() &&
		f.UnconsumedGrant >= f.BalanceCents:
		ent.Status = protocol.StatusTrial
		trialEnds := f.TrialEndsAt
		ent.TrialEndsAt = &trialEnds
	case f.BalanceCents >= MinBalanceCents:
		ent.Status = protocol.StatusActive
	default:
		ent.Status = protocol.StatusExhausted
		reason := protocol.EntitlementTrialExpired
		if f.HasAccount && f.TrialEndsAt == 0 {
			reason = protocol.EntitlementNoBalance
		}
		return decision(ent, reason)
	}
	if f.ActivePairs >= MaxActivePairs {
		return decision(ent, protocol.EntitlementConcurrency)
	}
	return decision(ent, "")
}

// decision stamps the ceiling the status implies, so no branch of Decide can answer
// without one and none of them has to remember to.
func decision(ent protocol.Entitlement, reason string) Decision {
	ent.Limits = protocol.Limits{MaxQuality: MaxQuality(ent.Status)}
	return Decision{Entitlement: ent, Reason: reason}
}
