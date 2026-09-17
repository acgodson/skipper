// Package entitlement is the server-side authorisation the signaling hub can
// legitimately make: may this host device open a session, and what does the user need to be told when it may not.
package entitlement

import (
	"context"

	protocol "rcprotocol"
)

type Decision struct {
	Allow  bool
	Reason string
}

var Allowed = Decision{Allow: true}

func Denied(reason string) Decision {
	if reason == "" {
		reason = protocol.EntitlementTrialExpired
	}
	return Decision{Reason: reason}
}

// Entitlement.KnownPair reports whether the controller has had a metered session with the host;
// the answer must survive a restart of the signaling server.
type Entitlement interface {
	Check(ctx context.Context, hostDeviceID string) (Decision, error)
	KnownPair(ctx context.Context, hostDeviceID, controllerDeviceID string) (bool, error)
	SessionStarted(ctx context.Context, r protocol.SessionStartReport) error
	SessionStopped(ctx context.Context, r protocol.SessionStopReport) error
}

func ValidReason(r string) bool {
	switch r {
	case protocol.EntitlementUnlinked, protocol.EntitlementTrialExpired,
		protocol.EntitlementNoBalance, protocol.EntitlementConcurrency,
		protocol.EntitlementSuspended:
		return true
	}
	return false
}
