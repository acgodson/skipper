package entitlement

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"rc-signal/internal/internalapi"
	"rc-signal/internal/reports"
	protocol "rcprotocol"
)

const CheckTimeout = internalapi.CallTimeout

type HTTP struct {
	api *internalapi.Client
}

func NewHTTP(api *internalapi.Client) *HTTP {
	return &HTTP{api: api}
}

func (h *HTTP) Check(ctx context.Context, hostDeviceID string) (Decision, error) {
	if !protocol.ValidDeviceID(hostDeviceID) {
		return Decision{}, errors.New("hostDeviceID must be 9 digits")
	}
	resp, err := h.api.Do(ctx, http.MethodGet, protocol.PathInternalEntitlement+"/"+hostDeviceID, nil)
	if err != nil {
		return Decision{}, err
	}
	switch {
	case resp.Status == http.StatusOK:
		var ent protocol.Entitlement
		if err := resp.Decode(&ent); err != nil {
			return Decision{}, err
		}
		return decideFrom(ent), nil
	case resp.Status == http.StatusPaymentRequired || resp.Status == http.StatusForbidden:
		apiErr := resp.APIError()
		if apiErr.Code == protocol.APIErrEntitlement && ValidReason(apiErr.Reason) {
			return Denied(apiErr.Reason), nil
		}
		if apiErr.Code == protocol.APIErrEntitlement {
			return Denied(protocol.EntitlementTrialExpired), nil
		}
		return Decision{}, fmt.Errorf("internal entitlement: %s", apiErr.Error())
	case resp.Status == http.StatusNotFound:
		return Denied(protocol.EntitlementUnlinked), nil
	default:
		return Decision{}, fmt.Errorf("internal entitlement: unexpected status %d", resp.Status)
	}
}

func decideFrom(ent protocol.Entitlement) Decision {
	switch ent.Status {
	case protocol.StatusTrial, protocol.StatusActive:
		return Allowed
	case protocol.StatusUnlinked:
		return Denied(protocol.EntitlementUnlinked)
	default:
		if ent.BalanceCents != nil {
			return Denied(protocol.EntitlementNoBalance)
		}
		return Denied(protocol.EntitlementTrialExpired)
	}
}

func (h *HTTP) KnownPair(ctx context.Context, hostDeviceID, controllerDeviceID string) (bool, error) {
	if !protocol.ValidDeviceID(hostDeviceID) || !protocol.ValidDeviceID(controllerDeviceID) {
		return false, errors.New("device ids must be 9 digits")
	}
	resp, err := h.api.Do(ctx, http.MethodGet, protocol.InternalPairPath(hostDeviceID, controllerDeviceID), nil)
	if err != nil {
		return false, err
	}
	if !resp.OK() {
		return false, fmt.Errorf("internal pair: unexpected status %d", resp.Status)
	}
	var pair protocol.InternalPair
	if err := resp.Decode(&pair); err != nil {
		return false, err
	}
	return pair.Known, nil
}

func (h *HTTP) SessionStarted(ctx context.Context, r protocol.SessionStartReport) error {
	return h.post(ctx, protocol.PathInternalSessionStart, r)
}

func (h *HTTP) SessionStopped(ctx context.Context, r protocol.SessionStopReport) error {
	return h.post(ctx, protocol.PathInternalSessionStop, r)
}

// post makes one attempt; the report queue owns retries and reads the error class.
func (h *HTTP) post(ctx context.Context, path string, payload any) error {
	resp, err := h.api.Do(ctx, http.MethodPost, path, payload)
	switch {
	case err != nil:
		return err
	case resp.OK():
		return nil
	case resp.Status == http.StatusPaymentRequired || resp.Status == http.StatusForbidden:
		return fmt.Errorf("%s: status %d: %w", path, resp.Status, reports.ErrDenied)
	case resp.Status >= 500 || resp.Status == http.StatusTooManyRequests:
		return fmt.Errorf("%s: status %d", path, resp.Status)
	default:
		return fmt.Errorf("%s: status %d: %w", path, resp.Status, reports.ErrPermanent)
	}
}
