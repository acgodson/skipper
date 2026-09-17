// Package internalapi is rc-signal's client for the rc-api internal surface
// (protocol/API.md §6): one base URL, one shared bearer secret, bounded calls.
package internalapi

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	protocol "rcprotocol"
)

const CallTimeout = 3 * time.Second

type Client struct {
	base  string
	token string
	http  *http.Client
}

type Response struct {
	Status int
	Body   []byte
}

func (r Response) OK() bool { return r.Status >= 200 && r.Status < 300 }

func (r Response) Decode(into any) error {
	if err := json.Unmarshal(r.Body, into); err != nil {
		return fmt.Errorf("internal API body: %w", err)
	}
	return nil
}

func (r Response) APIError() protocol.APIError { return protocol.DecodeAPIError(r.Body) }

func New(baseURL, token string) (*Client, error) {
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
	return &Client{base: baseURL, token: token, http: &http.Client{Timeout: CallTimeout}}, nil
}

// CheckSeparate refuses an internal listen address that shares a port with the public one.
func CheckSeparate(public, internal string) error {
	_, publicPort, errPublic := net.SplitHostPort(public)
	_, internalPort, errInternal := net.SplitHostPort(internal)
	if errInternal != nil {
		return fmt.Errorf("internal listen address %q: %w", internal, errInternal)
	}
	if errPublic == nil && publicPort == internalPort {
		return errors.New("the internal listener must not share the public listener's port")
	}
	return nil
}

// Authorized reports whether r carries the shared internal bearer secret.
// TODO: replace the bearer with mTLS or VPC-only reachability in Phase 5.
func Authorized(r *http.Request, token string) bool {
	presented, ok := strings.CutPrefix(r.Header.Get(protocol.HeaderAuthorization), protocol.BearerPrefix)
	if !ok || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(strings.TrimSpace(presented)), []byte(token)) == 1
}

// Do sends one call bounded by CallTimeout; a nil payload sends no body.
func (c *Client) Do(ctx context.Context, method, path string, payload any) (Response, error) {
	var body io.Reader
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return Response{}, err
		}
		body = bytes.NewReader(raw)
	}
	ctx, cancel := context.WithTimeout(ctx, CallTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, body)
	if err != nil {
		return Response{}, err
	}
	req.Header.Set(protocol.HeaderAuthorization, protocol.BearerPrefix+c.token)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return Response{}, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, protocol.APIMaxBodyBytes))
	if err != nil {
		return Response{}, err
	}
	return Response{Status: resp.StatusCode, Body: raw}, nil
}
