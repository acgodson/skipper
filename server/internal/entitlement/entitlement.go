// Package entitlement is the server-side authorisation the signaling hub can
// legitimately make: may this host device open a session at all, and what does
// the user need to be told when it may not.
//
// PROTOCOL.md §2.9 makes this the only gate on connect_req in v2 — the access
// code is proved peer to peer and never reaches the server. API.md §4.3 owns
// the closed set of deny reasons, mirrored by the protocol.Entitlement*
// constants, and API.md §6 owns the internal surface the http implementation
// speaks.
//
// Nothing here logs: a decision is metadata, but the device identities it
// carries belong to the hub's log lines, not to this package's.
package entitlement

import (
	"context"

	protocol "rcprotocol"
)

// Decision is the answer to one Check. A denial always carries a reason from
// API.md §4.3.
type Decision struct {
	Allow  bool
	Reason string
}

// Allowed is the decision that opens a session.
var Allowed = Decision{Allow: true}

// Denied builds a refusal with one of the protocol.Entitlement* reasons.
func Denied(reason string) Decision {
	if reason == "" {
		reason = protocol.EntitlementTrialExpired
	}
	return Decision{Reason: reason}
}

// Entitlement is what the hub holds. Check is on the connect_req path and is
// called without the hub lock held; the two reports are fire-and-forget
// accounting, and an implementation that talks to the network owns its own
// bounded retry rather than making the caller wait.
type Entitlement interface {
	Check(ctx context.Context, hostDeviceID string) (Decision, error)
	SessionStarted(ctx context.Context, r protocol.SessionStartReport) error
	SessionStopped(ctx context.Context, r protocol.SessionStopReport) error
}

// ValidReason reports whether r is one of the API.md §4.3 reasons.
func ValidReason(r string) bool {
	switch r {
	case protocol.EntitlementUnlinked, protocol.EntitlementTrialExpired,
		protocol.EntitlementNoBalance, protocol.EntitlementConcurrency,
		protocol.EntitlementSuspended:
		return true
	}
	return false
}
