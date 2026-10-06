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
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"rc-signal/internal/envx"
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

// Secret names every way the internal bearer can be given, in the order they
// are preferred: a file, the environment, and last the flag form.
type Secret struct {
	FilePath     string
	FileFlagName string
	Env          string
	EnvName      string
	Flag         string
	FlagName     string
}

// ResolveSecret reads the internal bearer, preferring the file form. The flag
// form still works and is warned about: a process argument is readable by every
// local user through ps and /proc/<pid>/cmdline.
func ResolveSecret(s Secret, log *slog.Logger) (string, error) {
	secret, err := envx.SecretFile(s.FilePath, "internal token")
	if err != nil || secret != "" {
		return secret, err
	}
	if fromEnv := strings.TrimSpace(s.Env); fromEnv != "" {
		return fromEnv, nil
	}
	if fromFlag := strings.TrimSpace(s.Flag); fromFlag != "" {
		log.Warn("the internal token was passed as a process argument, where every local user can read it; "+
			"pass it in a file instead",
			"deprecated", "-"+s.FlagName, "use", "-"+s.FileFlagName, "or", s.EnvName)
		return fromFlag, nil
	}
	return "", nil
}

// CheckLoopback refuses an internal listener reachable from off this machine.
// The internal surface carries a shared bearer and nothing else (API.md §6), so
// exposing it is an explicit choice, never a default.
func CheckLoopback(addr string, allowPublic bool) error {
	if allowPublic {
		return nil
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("internal listen address %q: %w", addr, err)
	}
	if host == "localhost" {
		return nil
	}
	if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil && ip.IsLoopback() {
		return nil
	}
	return fmt.Errorf("the internal listener %q is reachable from outside this machine: "+
		"bind it to 127.0.0.1 or pass -internal-listen-public", addr)
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
