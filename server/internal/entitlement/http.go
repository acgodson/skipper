package entitlement

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	protocol "rcprotocol"
)

const (
	CheckTimeout   = 3 * time.Second
	ReportTimeout  = 3 * time.Second
	ReportAttempts = 3
	ReportBackoff  = 250 * time.Millisecond
)

type HTTP struct {
	base   string
	token  string
	client *http.Client
}

func NewHTTP(baseURL, token string) (*HTTP, error) {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		return nil, errors.New("internal API base URL is required")
	}
	u, err := url.Parse(baseURL)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("internal API base URL %q is not an absolute URL", baseURL)
	}
	if strings.TrimSpace(token) == "" {
		return nil, errors.New("internal API bearer token is required")
	}
	return &HTTP{
		base:   baseURL,
		token:  token,
		client: &http.Client{Timeout: CheckTimeout},
	}, nil
}

func (h *HTTP) Check(ctx context.Context, hostDeviceID string) (Decision, error) {
	if !protocol.ValidDeviceID(hostDeviceID) {
		return Decision{}, errors.New("hostDeviceID must be 9 digits")
	}
	target := h.base + protocol.PathInternalEntitlement + "/" + hostDeviceID
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return Decision{}, err
	}
	req.Header.Set(protocol.HeaderAuthorization, protocol.BearerPrefix+h.token)
	resp, err := h.client.Do(req)
	if err != nil {
		return Decision{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, protocol.APIMaxBodyBytes))
	if err != nil {
		return Decision{}, err
	}
	switch {
	case resp.StatusCode == http.StatusOK:
		var ent protocol.Entitlement
		if err := json.Unmarshal(body, &ent); err != nil {
			return Decision{}, fmt.Errorf("entitlement body: %w", err)
		}
		return decideFrom(ent), nil
	case resp.StatusCode == http.StatusPaymentRequired || resp.StatusCode == http.StatusForbidden:
		apiErr := protocol.DecodeAPIError(body)
		if apiErr.Code == protocol.APIErrEntitlement && ValidReason(apiErr.Reason) {
			return Denied(apiErr.Reason), nil
		}
		if apiErr.Code == protocol.APIErrEntitlement {
			return Denied(protocol.EntitlementTrialExpired), nil
		}
		return Decision{}, fmt.Errorf("internal entitlement: %s", apiErr.Error())
	case resp.StatusCode == http.StatusNotFound:
		return Denied(protocol.EntitlementUnlinked), nil
	default:
		return Decision{}, fmt.Errorf("internal entitlement: unexpected status %d", resp.StatusCode)
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
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
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
		retry, err := h.postOnce(ctx, path, body)
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

func (h *HTTP) postOnce(ctx context.Context, path string, body []byte) (bool, error) {
	reqCtx, cancel := context.WithTimeout(ctx, ReportTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, h.base+path, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set(protocol.HeaderAuthorization, protocol.BearerPrefix+h.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.client.Do(req)
	if err != nil {
		return true, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, protocol.APIMaxBodyBytes))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return false, nil
	}
	retry := resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests
	return retry, fmt.Errorf("%s: unexpected status %d", path, resp.StatusCode)
}
