// Package internalapi is rc-signal's client for the rc-api internal surface
// (protocol/API.md §6): one base URL, one shared bearer secret, bounded calls.
package internalapi

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
