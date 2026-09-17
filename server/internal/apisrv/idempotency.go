package apisrv

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"

	protocol "rcprotocol"
)

type captureWriter struct {
	headers http.Header
	status  int
	body    []byte
}

func (c *captureWriter) Header() http.Header {
	if c.headers == nil {
		c.headers = http.Header{}
	}
	return c.headers
}

func (c *captureWriter) WriteHeader(status int) {
	if c.status == 0 {
		c.status = status
	}
}

func (c *captureWriter) Write(b []byte) (int, error) {
	if c.status == 0 {
		c.status = http.StatusOK
	}
	c.body = append(c.body, b...)
	return len(b), nil
}

func (s *Server) replay(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set(protocol.HeaderIdempotencyReplayed, "true")
	if len(body) == 0 || status == http.StatusNoContent {
		w.WriteHeader(status)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// idempotent runs handler at most once per (caller, endpoint, key) for 24 hours
// and replays the stored answer afterwards (API.md §0.6).
func (s *Server) idempotent(w http.ResponseWriter, r *http.Request, caller string, body []byte, handler func(http.ResponseWriter)) {
	key := r.Header.Get(protocol.HeaderIdempotencyKey)
	if !protocol.ValidIdempotencyKey(key) {
		s.badRequest(w, r, "this endpoint requires an Idempotency-Key of 16 to 64 characters")
		return
	}
	sum := sha256.Sum256(body)
	hash := hex.EncodeToString(sum[:])
	scope := caller + "|" + r.Method + " " + r.URL.Path
	stored, err := s.opt.DB.BeginIdempotent(scope, key, hash, s.nowMS())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	if stored != nil {
		switch {
		case stored.BodyHash != hash:
			s.fail(w, r, http.StatusConflict, protocol.APIErrIdempotencyConflict,
				"this idempotency key was used with a different body", withReason(protocol.ReasonBodyMismatch))
		case !stored.Done:
			s.fail(w, r, http.StatusConflict, protocol.APIErrConflict,
				"the first call with this idempotency key is still running", withReason(protocol.ReasonInProgress))
		default:
			s.replay(w, stored.Status, stored.Response)
		}
		return
	}
	capture := &captureWriter{}
	handler(capture)
	if capture.status == 0 {
		capture.status = http.StatusOK
	}
	if capture.status >= http.StatusInternalServerError {
		_ = s.opt.DB.ReleaseIdempotent(scope, key)
	} else if err := s.opt.DB.CompleteIdempotent(scope, key, capture.status, capture.body); err != nil {
		s.internalError(w, r, err)
		return
	}
	for name, values := range capture.Header() {
		for _, v := range values {
			w.Header().Add(name, v)
		}
	}
	w.WriteHeader(capture.status)
	_, _ = w.Write(capture.body)
}
