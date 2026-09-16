package entitlement

import (
	"context"
	"fmt"
	"strings"

	protocol "rcprotocol"
)

// DevDenyLabel is the device label that a Static provider refuses when no deny
// list is configured. It exists so a local run — and the smoke test, which
// cannot know a freshly minted device id in advance — can exercise the deny
// path without any server configuration.
const DevDenyLabel = "entitlement-denied"

// LabelFunc resolves a device's stored label. Static uses it for label rules;
// a nil LabelFunc simply makes those rules unmatchable.
type LabelFunc func(deviceID string) string

// Static is the development provider: every host is entitled unless it matches
// the deny list. It never talks to the network, and its session reports are
// no-ops because no accounting service exists in this mode.
type Static struct {
	denyIDs    map[string]string
	denyLabels map[string]string
	labelOf    LabelFunc
}

// NewStatic parses a deny-list specification: comma-separated entries, each
//
//	<deviceId>[=<reason>]
//	label:<label>[=<reason>]
//
// with the reason defaulting to trial_expired. An empty spec installs the
// single DevDenyLabel rule.
func NewStatic(spec string, labelOf LabelFunc) (*Static, error) {
	s := &Static{
		denyIDs:    map[string]string{},
		denyLabels: map[string]string{},
		labelOf:    labelOf,
	}
	if strings.TrimSpace(spec) == "" {
		s.denyLabels[DevDenyLabel] = protocol.EntitlementTrialExpired
		return s, nil
	}
	for _, entry := range strings.Split(spec, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		match, reason, ok := strings.Cut(entry, "=")
		if !ok || reason == "" {
			reason = protocol.EntitlementTrialExpired
		}
		if !ValidReason(reason) {
			return nil, fmt.Errorf("deny entry %q: unknown reason %q", entry, reason)
		}
		if label, isLabel := strings.CutPrefix(match, "label:"); isLabel {
			if label == "" {
				return nil, fmt.Errorf("deny entry %q: empty label", entry)
			}
			s.denyLabels[label] = reason
			continue
		}
		if !protocol.ValidDeviceID(match) {
			return nil, fmt.Errorf("deny entry %q: %q is neither a 9-digit deviceId nor label:<label>", entry, match)
		}
		s.denyIDs[match] = reason
	}
	return s, nil
}

// Check applies the deny list and otherwise allows.
func (s *Static) Check(_ context.Context, hostDeviceID string) (Decision, error) {
	if reason, denied := s.denyIDs[hostDeviceID]; denied {
		return Denied(reason), nil
	}
	if s.labelOf != nil && len(s.denyLabels) > 0 {
		if reason, denied := s.denyLabels[s.labelOf(hostDeviceID)]; denied {
			return Denied(reason), nil
		}
	}
	return Allowed, nil
}

// SessionStarted is a no-op: there is no accounting service in static mode.
func (s *Static) SessionStarted(context.Context, protocol.SessionStartReport) error { return nil }

// SessionStopped is a no-op for the same reason.
func (s *Static) SessionStopped(context.Context, protocol.SessionStopReport) error { return nil }
