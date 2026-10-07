// Package apisrv is the rc-api HTTP surface: every endpoint of protocol/API.md
// on the public handler, and the internal surface the signaling server calls on
// a separate handler that is served on its own listener.
package apisrv

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"time"

	"rc-signal/internal/apidb"
	"rc-signal/internal/clientip"
	"rc-signal/internal/idcert"
	"rc-signal/internal/idp"
	"rc-signal/internal/internalapi"
	"rc-signal/internal/ratelimit"
	protocol "rcprotocol"
)

type Options struct {
	DB             *apidb.DB
	IdP            idp.Provider
	IDCert         *idcert.Authority
	InternalToken  string
	HardwareSalt   []byte
	WebBaseURL     string
	SignalUpstream string
	ClientIP       clientip.Resolver
	CloseSessions  CloseSessions
	Logger         *slog.Logger
	Now            func() time.Time
}

// CloseSessions ends every live session a device takes part in, over rc-signal's
// internal surface (API.md §6). It is absent in a deployment without signaling.
type CloseSessions func(ctx context.Context, deviceID, reason string) error

type Server struct {
	opt       Options
	mux       *http.ServeMux
	internal  *http.ServeMux
	limiter   *ratelimit.Limiter
	proxy     *httputil.ReverseProxy
	webOrigin string
}

const callbackScheme = "skipperdesk://link"

func New(opt Options) (*Server, error) {
	if opt.DB == nil || opt.IdP == nil {
		return nil, errors.New("rc-api needs a database and an identity provider")
	}
	if opt.IDCert == nil {
		return nil, errors.New("rc-api needs a device-id certificate authority")
	}
	if len(opt.HardwareSalt) == 0 {
		return nil, errors.New("rc-api needs a hardware salt")
	}
	if strings.TrimSpace(opt.InternalToken) == "" {
		return nil, errors.New("rc-api needs an internal bearer token")
	}
	if opt.Logger == nil {
		opt.Logger = slog.Default()
	}
	if opt.Now == nil {
		opt.Now = time.Now
	}
	origin, err := webOriginOf(opt.WebBaseURL)
	if err != nil {
		return nil, err
	}
	s := &Server{opt: opt, mux: http.NewServeMux(), internal: http.NewServeMux(),
		limiter: ratelimit.New(), webOrigin: origin}
	if err := s.buildProxy(); err != nil {
		return nil, err
	}
	s.routes()
	return s, nil
}

func (s *Server) now() time.Time { return s.opt.Now() }

func (s *Server) nowMS() int64 { return s.now().UnixMilli() }

func millis(ms int64) time.Duration { return time.Duration(ms) * time.Millisecond }

func (s *Server) routes() {
	m := s.mux
	m.HandleFunc("GET /v1/health", s.health)
	m.HandleFunc("GET /healthz", s.healthz)
	m.HandleFunc("GET "+protocol.PathAppReleasesLatest, s.latestRelease)

	m.HandleFunc("POST /v1/auth/link", s.browserCallable(s.authLink))
	m.HandleFunc("OPTIONS /v1/auth/link", s.browserCallable(s.linkPreflight))
	m.HandleFunc("POST /v1/auth/device/challenge", s.authChallenge)
	m.HandleFunc("POST /v1/auth/device/token", s.authToken)
	m.HandleFunc("POST /v1/auth/device/refresh", s.authRefresh)
	m.HandleFunc("POST /v1/auth/device/revoke", s.authRevoke)

	m.HandleFunc("GET /v1/devices", s.listDevices)
	m.HandleFunc("GET /v1/devices/{deviceId}", s.getDevice)
	m.HandleFunc("PATCH /v1/devices/{deviceId}", s.renameDevice)
	m.HandleFunc("DELETE /v1/devices/{deviceId}", s.unlinkDevice)

	m.HandleFunc("GET /v1/entitlement", s.entitlement)
	m.HandleFunc("GET /v1/sessions", s.listSessions)

	m.HandleFunc("GET /v1/credits", s.credits)
	m.HandleFunc("GET /v1/credits/ledger", s.creditsLedger)
	m.HandleFunc("POST /v1/credits/dev-topup", s.devTopup)
	m.HandleFunc("POST /v1/dev/expire-trial", s.devExpireTrial)
	m.HandleFunc("POST "+protocol.PathDevReleases, s.devPublishRelease)
	m.HandleFunc("POST /v1/credits/gifts", s.createGift)
	m.HandleFunc("GET /v1/credits/gifts", s.listGifts)
	m.HandleFunc("POST /v1/credits/gifts/{giftId}/accept", s.acceptGift)
	m.HandleFunc("POST /v1/credits/gifts/{giftId}/cancel", s.cancelGift)

	if s.opt.IdP.Name() == "dev" {
		m.HandleFunc("GET /link", s.linkPage)
		m.HandleFunc("POST /link", s.linkSubmit)
	}
	m.HandleFunc("/ws", s.proxyWS)
	m.HandleFunc("/", s.notFound)

	in := s.internal
	in.HandleFunc("GET "+protocol.PathInternalEntitlement+"/{deviceId}", s.internalOnly(s.internalEntitlement))
	in.HandleFunc("POST "+protocol.PathInternalRegister, s.internalOnly(s.internalRegister))
	in.HandleFunc("GET "+protocol.PathInternalDevices+"/{deviceId}", s.internalOnly(s.internalDeviceRead))
	in.HandleFunc("POST "+protocol.PathInternalDevices+"/{deviceId}"+protocol.InternalEpochSuffix, s.internalOnly(s.internalEpoch))
	in.HandleFunc("POST "+protocol.PathInternalDevices+"/{deviceId}"+protocol.InternalCertSuffix, s.internalOnly(s.internalDeviceCert))
	in.HandleFunc("GET "+protocol.PathInternalPairs+"/{hostDeviceId}/{controllerDeviceId}", s.internalOnly(s.internalPair))
	in.HandleFunc("POST "+protocol.PathInternalSessionStart, s.internalOnly(s.internalSessionStart))
	in.HandleFunc("POST "+protocol.PathInternalSessionStop, s.internalOnly(s.internalSessionStop))
	in.HandleFunc("POST "+protocol.PathInternalReleases, s.internalOnly(s.publishRelease))
	in.HandleFunc("GET /healthz", s.healthz)
	in.HandleFunc("/", s.notFound)
}

type ctxKey string

const requestIDKey ctxKey = "requestId"

// ServeHTTP is the public surface.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.serve(s.mux, w, r)
}

// InternalHandler is API.md §6; it is served only on the internal listener.
func (s *Server) InternalHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.serve(s.internal, w, r)
	})
}

func (s *Server) serve(mux *http.ServeMux, w http.ResponseWriter, r *http.Request) {
	id := newRequestID()
	w.Header().Set(protocol.HeaderRequestID, id)
	w.Header().Set("Date", s.now().UTC().Format(http.TimeFormat))
	r = r.WithContext(context.WithValue(r.Context(), requestIDKey, id))
	started := s.now()
	recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	mux.ServeHTTP(recorder, r)
	s.opt.Logger.Info("request", "requestId", id, "method", r.Method, "path", r.URL.Path,
		"status", recorder.status, "ms", s.now().Sub(started).Milliseconds())
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := s.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("this response cannot be hijacked")
	}
	return h.Hijack()
}

func requestID(r *http.Request) string {
	if id, ok := r.Context().Value(requestIDKey).(string); ok {
		return id
	}
	return ""
}

func newRequestID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "0"
	}
	return strings.ToUpper(hex.EncodeToString(b))
}

// --- responses --------------------------------------------------------------

func (s *Server) writeJSON(w http.ResponseWriter, r *http.Request, status int, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, protocol.APIErrInternal, "the answer could not be encoded")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

type failOption func(*protocol.APIError)

func withReason(reason string) failOption {
	return func(e *protocol.APIError) { e.Reason = reason }
}

func withRetryAfter(sec int) failOption {
	return func(e *protocol.APIError) { e.RetryAfterSec = sec }
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, status int, code, message string, opts ...failOption) {
	e := protocol.APIError{Code: code, Message: message, RequestID: requestID(r)}
	for _, o := range opts {
		o(&e)
	}
	if e.RetryAfterSec > 0 {
		w.Header().Set(protocol.HeaderRetryAfter, strconv.Itoa(e.RetryAfterSec))
	}
	body, _ := json.Marshal(protocol.APIErrorBody{Error: e})
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func (s *Server) badRequest(w http.ResponseWriter, r *http.Request, message string) {
	s.fail(w, r, http.StatusBadRequest, protocol.APIErrBadRequest, message)
}

func (s *Server) internalError(w http.ResponseWriter, r *http.Request, err error) {
	s.opt.Logger.Error("request failed", "requestId", requestID(r), "path", r.URL.Path, "err", err)
	s.fail(w, r, http.StatusInternalServerError, protocol.APIErrInternal, "the server could not complete this call")
}

func (s *Server) notFound(w http.ResponseWriter, r *http.Request) {
	s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such path")
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if !s.allow(w, r, limitHealth, s.clientIP(r)) {
		return
	}
	s.writeJSON(w, r, http.StatusOK, protocol.Health{Status: "ok", ServerTime: s.nowMS()})
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// --- requests ---------------------------------------------------------------

func (s *Server) readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(io.LimitReader(r.Body, protocol.APIMaxBodyBytes+1))
	if err != nil {
		s.badRequest(w, r, "the body could not be read")
		return nil, false
	}
	if len(body) > protocol.APIMaxBodyBytes {
		s.fail(w, r, http.StatusRequestEntityTooLarge, protocol.APIErrBadRequest, "the body is larger than 64 KiB")
		return nil, false
	}
	return body, true
}

func (s *Server) decode(w http.ResponseWriter, r *http.Request, body []byte, into any) bool {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if len(bytes.TrimSpace(body)) == 0 {
		body = []byte("{}")
		dec = json.NewDecoder(bytes.NewReader(body))
		dec.DisallowUnknownFields()
	}
	if err := dec.Decode(into); err != nil {
		s.badRequest(w, r, "the body is not the expected JSON object: "+err.Error())
		return false
	}
	if dec.More() {
		s.badRequest(w, r, "the body carries more than one JSON value")
		return false
	}
	return true
}

func bearer(r *http.Request) string {
	header := r.Header.Get(protocol.HeaderAuthorization)
	rest, ok := strings.CutPrefix(header, protocol.BearerPrefix)
	if !ok {
		return ""
	}
	return strings.TrimSpace(rest)
}

func (s *Server) clientIP(r *http.Request) string { return s.opt.ClientIP.Of(r) }

// --- credentials ------------------------------------------------------------

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (s *Server) hardwareHash(hardwareID string) string {
	mac := hmac.New(sha256.New, s.opt.HardwareSalt)
	mac.Write([]byte(hardwareID))
	return hex.EncodeToString(mac.Sum(nil))
}

// userSession authenticates the website's credential and refuses a device token
// presented to a user-session endpoint (API.md §0.2).
func (s *Server) userSession(w http.ResponseWriter, r *http.Request) (*apidb.Account, bool) {
	token := bearer(r)
	if token == "" {
		s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "a user session is required")
		return nil, false
	}
	if _, err := s.opt.DB.TokenByHash(tokenHash(token)); err == nil {
		s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "a device token is not accepted here")
		return nil, false
	}
	session, err := s.opt.IdP.UserSession(r.Context(), token)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "that user session is not valid")
		return nil, false
	}
	account, err := s.opt.DB.EnsureAccount(session.AccountID, session.Email, s.now())
	if err != nil {
		s.internalError(w, r, err)
		return nil, false
	}
	return account, true
}

// deviceAuth authenticates a device token and refuses a user session presented
// to a device endpoint.
func (s *Server) deviceAuth(w http.ResponseWriter, r *http.Request) (*apidb.Device, *apidb.DeviceToken, bool) {
	raw := bearer(r)
	if raw == "" {
		s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "a device token is required")
		return nil, nil, false
	}
	token, err := s.opt.DB.TokenByHash(tokenHash(raw))
	if errors.Is(err, apidb.ErrNotFound) {
		if _, idpErr := s.opt.IdP.UserSession(r.Context(), raw); idpErr == nil {
			s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "a user session is not accepted here")
			return nil, nil, false
		}
		s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "that device token is not valid")
		return nil, nil, false
	}
	if err != nil {
		s.internalError(w, r, err)
		return nil, nil, false
	}
	if token.Revoked || token.ExpiresAt < s.nowMS() {
		s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "that device token is no longer valid")
		return nil, nil, false
	}
	device, err := s.opt.DB.DeviceByID(token.DeviceID)
	if err != nil {
		s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "that device is not linked",
			withReason(protocol.EntitlementUnlinked))
		return nil, nil, false
	}
	if device.Unlinked {
		s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "that device was unlinked",
			withReason(protocol.EntitlementUnlinked))
		return nil, nil, false
	}
	if err := s.opt.DB.TouchDevice(device.DeviceID, s.nowMS()); err != nil {
		s.internalError(w, r, err)
		return nil, nil, false
	}
	return device, token, true
}

func (s *Server) internalOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !internalapi.Authorized(r, s.opt.InternalToken) {
			s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "the internal surface needs its own token")
			return
		}
		next(w, r)
	}
}

// --- paging -----------------------------------------------------------------

func encodeCursor(at int64, id string, issued int64) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(at, 10) + "|" + id + "|" +
		strconv.FormatInt(issued, 10)))
}

func (s *Server) decodeCursor(cursor string) (at int64, id string, ok bool) {
	if cursor == "" {
		return 0, "", true
	}
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return 0, "", false
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 3 {
		return 0, "", false
	}
	at, err = strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, "", false
	}
	issued, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || s.nowMS()-issued > int64(protocol.CursorTTLSec)*1000 {
		return 0, "", false
	}
	return at, parts[1], true
}

func (s *Server) intQuery(w http.ResponseWriter, r *http.Request, name string, def, min, max int) (int, bool) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def, true
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v < min || v > max {
		s.badRequest(w, r, "'"+name+"' must be between "+strconv.Itoa(min)+" and "+strconv.Itoa(max))
		return 0, false
	}
	return v, true
}

func (s *Server) msQuery(w http.ResponseWriter, r *http.Request, name string, required bool) (int64, bool) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		if required {
			s.badRequest(w, r, "'"+name+"' is required")
			return 0, false
		}
		return 0, true
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || v < 0 {
		s.badRequest(w, r, "'"+name+"' must be a Unix millisecond timestamp")
		return 0, false
	}
	return v, true
}

func knownQuery(r *http.Request, allowed ...string) bool {
	for name := range r.URL.Query() {
		found := false
		for _, a := range allowed {
			if name == a {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// --- /ws passthrough --------------------------------------------------------

// TODO: in AWS the WebSocket is a separate ALB route to the signaling service.
// This proxy exists so that a local rc-api serves the one base URL the app knows.
func (s *Server) buildProxy() error {
	if strings.TrimSpace(s.opt.SignalUpstream) == "" {
		return nil
	}
	target, err := url.Parse(strings.TrimRight(s.opt.SignalUpstream, "/"))
	if err != nil || target.Scheme == "" || target.Host == "" {
		return errors.New("the signaling upstream must be an absolute URL")
	}
	s.proxy = &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.Host = pr.In.Host
			pr.Out.Header.Set(protocol.HeaderForwardedFor, s.clientIP(pr.In))
			if upgrade := pr.In.Header.Get("Upgrade"); upgrade != "" {
				pr.Out.Header.Set("Connection", "Upgrade")
				pr.Out.Header.Set("Upgrade", upgrade)
			}
		},
	}
	return nil
}

func (s *Server) proxyWS(w http.ResponseWriter, r *http.Request) {
	if s.proxy == nil {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "this deployment does not proxy the signaling socket")
		return
	}
	s.proxy.ServeHTTP(w, r)
}
