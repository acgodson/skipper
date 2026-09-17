package entitlement

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"rc-signal/internal/internalapi"
	protocol "rcprotocol"
)

const (
	CheckTimeout   = internalapi.CallTimeout
	ReportAttempts = 3
	ReportBackoff  = 250 * time.Millisecond
)

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

func (h *HTTP) SessionStarted(ctx context.Context, r protocol.SessionStartReport) error {
	return h.post(ctx, protocol.PathInternalSessionStart, r)
}

func (h *HTTP) SessionStopped(ctx context.Context, r protocol.SessionStopReport) error {
	return h.post(ctx, protocol.PathInternalSessionStop, r)
}

func (h *HTTP) post(ctx context.Context, path string, payload any) error {
	var last error
	for attempt := 0; attempt < ReportAttempts; attempt++ {
		if attempt > 0 {
			delay := ReportBackoff << (attempt - 1)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}
		}
		retry, err := h.postOnce(ctx, path, payload)
		if err == nil {
			return nil
		}
		last = err
		if !retry {
			return err
		}
	}
	return last
}

func (h *HTTP) postOnce(ctx context.Context, path string, payload any) (bool, error) {
	resp, err := h.api.Do(ctx, http.MethodPost, path, payload)
	if err != nil {
		return true, err
	}
	if resp.OK() {
		return false, nil
	}
	retry := resp.Status >= 500 || resp.Status == http.StatusTooManyRequests
	return retry, fmt.Errorf("%s: unexpected status %d", path, resp.Status)
}
