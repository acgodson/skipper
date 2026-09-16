package entitlement

import (
	"context"
	"fmt"
	"strings"

	protocol "rcprotocol"
)

const DevDenyLabel = "entitlement-denied"

type LabelFunc func(deviceID string) string

type Static struct {
	denyIDs    map[string]string
	denyLabels map[string]string
	labelOf    LabelFunc
}

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

func (s *Static) SessionStarted(context.Context, protocol.SessionStartReport) error { return nil }

func (s *Static) SessionStopped(context.Context, protocol.SessionStopReport) error { return nil }
