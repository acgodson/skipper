package apisrv

// CORS for `POST /v1/auth/link` and nothing else (API.md §1.2). That route is the
// only one a browser calls: the website is a different origin from the API, so
// without these headers the call never leaves the page. Every other route is
// reached by the desktop app, which is not subject to the same-origin policy, and
// every route that grows these headers is a route someone has to review.
//
// Two details are load-bearing and silently wrong if dropped:
//
//   - The headers go on *every* answer, not just the 201. A `409 linked_elsewhere`
//     whose body the browser is not allowed to read degrades into a generic
//     failure, and the one message that tells an owner their Mac belongs to
//     another account never reaches the screen.
//   - `Access-Control-Allow-Credentials` stays off. The credential here is a
//     bearer header the page puts on the request itself, not a cookie the browser
//     attaches, so turning it on would widen the surface and buy nothing.

import (
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const (
	headerOrigin       = "Origin"
	headerAllowOrigin  = "Access-Control-Allow-Origin"
	headerAllowMethods = "Access-Control-Allow-Methods"
	headerAllowHeaders = "Access-Control-Allow-Headers"
	headerCORSMaxAge   = "Access-Control-Max-Age"
	headerVary         = "Vary"
	corsAllowedHeaders = "Authorization, Content-Type, Idempotency-Key"

	// Chrome clamps a preflight cache to 600 s and silently ignores more, so
	// anything larger would only be a number that reads as longer than it is.
	corsPreflightMaxAge = 600
)

var errWebBaseURL = errors.New("the website base URL must be an absolute http or https URL")

// webOriginOf reduces the `-web-base-url` flag to the one origin a browser may
// send, so the allowlist and the page's own address can never drift apart.
func webOriginOf(webBaseURL string) (string, error) {
	raw := strings.TrimSpace(webBaseURL)
	if raw == "" {
		return "", nil
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return "", errWebBaseURL
	}
	return parsed.Scheme + "://" + parsed.Host, nil
}

// fromWebOrigin is an exact match against the configured origin. A request from
// anywhere else gets no CORS header at all and the browser does the refusing;
// there is no status code that would mean anything to the page.
func (s *Server) fromWebOrigin(r *http.Request) bool {
	return s.webOrigin != "" && r.Header.Get(headerOrigin) == s.webOrigin
}

func (s *Server) browserCallable(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(headerVary, headerOrigin)
		if s.fromWebOrigin(r) {
			w.Header().Set(headerAllowOrigin, s.webOrigin)
		}
		next(w, r)
	}
}

func (s *Server) linkPreflight(w http.ResponseWriter, r *http.Request) {
	if s.fromWebOrigin(r) {
		w.Header().Set(headerAllowMethods, http.MethodPost)
		w.Header().Set(headerAllowHeaders, corsAllowedHeaders)
		w.Header().Set(headerCORSMaxAge, strconv.Itoa(corsPreflightMaxAge))
	}
	w.WriteHeader(http.StatusNoContent)
}
