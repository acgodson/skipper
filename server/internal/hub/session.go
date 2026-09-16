package hub

import (
	"crypto/rand"
	"encoding/hex"
	"time"

	"rc-signal/internal/auth"
	"rcprotocol"
)

// side is one participant's server-side session state.
type side struct {
	deviceID string
	conn     *Client
	nonce    string    // current token nonce; rotating it kills the previous token
	expiry   time.Time // current token expiry
	epoch    int64     // device code epoch at issue time
}

// Session is server-side state that deliberately outlives any WebSocket.
// See PROTOCOL.md §4. It holds no SDP, no candidates, no media state.
type Session struct {
	ID        string
	State     string
	Host      side
	Ctrl      side
	CreatedAt time.Time
}

func newSessionID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func (s *Session) sideFor(deviceID string) *side {
	switch deviceID {
	case s.Host.deviceID:
		return &s.Host
	case s.Ctrl.deviceID:
		return &s.Ctrl
	}
	return nil
}

func (s *Session) peerOf(deviceID string) *side {
	switch deviceID {
	case s.Host.deviceID:
		return &s.Ctrl
	case s.Ctrl.deviceID:
		return &s.Host
	}
	return nil
}

func (s *Session) roleOf(deviceID string) string {
	if deviceID == s.Host.deviceID {
		return protocol.RoleHost
	}
	return protocol.RoleController
}

// expiredLocked reports whether the session should die: every DETACHED side's
// token has expired, so nobody can resume it any more. An attached side keeps
// the session alive regardless (it renews).
func (s *Session) expiredLocked(now time.Time) bool {
	if s.State == protocol.SessionOpen || s.State == protocol.SessionPending {
		return false
	}
	anyDetached := false
	for _, sd := range []*side{&s.Host, &s.Ctrl} {
		if sd.conn == nil {
			anyDetached = true
			if now.Before(sd.expiry) {
				return false // still resumable by this side
			}
		}
	}
	return anyDetached
}

// recomputeStateLocked derives open/half_open/orphaned from attachment.
func (s *Session) recomputeStateLocked() {
	if s.State == protocol.SessionClosed || s.State == protocol.SessionPending {
		return
	}
	switch {
	case s.Host.conn != nil && s.Ctrl.conn != nil:
		s.State = protocol.SessionOpen
	case s.Host.conn == nil && s.Ctrl.conn == nil:
		s.State = protocol.SessionOrphaned
	default:
		s.State = protocol.SessionHalfOpen
	}
}

// State returns a session's state (test hook).
func (h *Hub) SessionState(id string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.sessions[id]
	if s == nil {
		return ""
	}
	return s.State
}

// issueTokenLocked rotates the token nonce for one side and mints a new token.
func (h *Hub) issueTokenLocked(s *Session, sd *side, now time.Time) (string, time.Time, error) {
	n, err := auth.NewTokenNonce()
	if err != nil {
		return "", time.Time{}, err
	}
	sd.nonce = n
	sd.expiry = now.Add(SessionTokenTTL)
	tok := h.opt.Signer.Mint(auth.TokenClaims{
		SessionID: s.ID, DeviceID: sd.deviceID, Expiry: sd.expiry,
		Epoch: sd.epoch, Nonce: n,
	})
	return tok, sd.expiry, nil
}

// verifyTokenLocked applies every check from PROTOCOL.md §3.2.
// It returns the session and the caller's side, or a protocol error code.
func (h *Hub) verifyTokenLocked(deviceID, sessionID, token string, now time.Time) (*Session, *side, string) {
	claims, err := h.opt.Signer.Parse(token)
	if err != nil {
		return nil, nil, protocol.ErrBadToken
	}
	s := h.sessions[sessionID]
	if s == nil || s.State == protocol.SessionClosed {
		return nil, nil, protocol.ErrNoSession
	}
	if claims.SessionID != sessionID || claims.DeviceID != deviceID {
		return nil, nil, protocol.ErrBadToken
	}
	sd := s.sideFor(deviceID)
	if sd == nil {
		return nil, nil, protocol.ErrBadToken
	}
	if claims.Nonce != sd.nonce || claims.Epoch != sd.epoch {
		return nil, nil, protocol.ErrBadToken
	}
	if !now.Before(claims.Expiry) || !now.Before(sd.expiry) {
		return nil, nil, protocol.ErrBadToken
	}
	return s, sd, ""
}

// attachLocked binds a connection to a session side and notifies the peer.
func (h *Hub) attachLocked(s *Session, sd *side, c *Client) {
	if sd.conn != nil && sd.conn != c {
		sd.conn.sessionID = ""
	}
	sd.conn = c
	c.sessionID = s.ID
	if s.State == protocol.SessionPending && s.Host.conn != nil && s.Ctrl.conn != nil {
		s.State = protocol.SessionOpen
	}
	s.recomputeStateLocked()
	if peer := s.peerOf(sd.deviceID); peer != nil && peer.conn != nil {
		h.sendLocked(peer.conn, protocol.TypePeerState, "", protocol.PeerState{
			SessionID: s.ID, Attached: true})
	}
}

// detachLocked unbinds a dropped connection. The session stays alive.
func (h *Hub) detachLocked(c *Client) {
	s := h.sessions[c.sessionID]
	c.sessionID = ""
	if s == nil || s.State == protocol.SessionClosed {
		return
	}
	sd := s.sideFor(c.deviceID)
	if sd == nil || sd.conn != c {
		return
	}
	sd.conn = nil
	s.recomputeStateLocked()
	if peer := s.peerOf(sd.deviceID); peer != nil && peer.conn != nil {
		h.sendLocked(peer.conn, protocol.TypePeerState, "", protocol.PeerState{
			SessionID: s.ID, Attached: false})
	}
}

// closeSessionLocked is terminal: both sides get bye, all state is dropped and
// the host's 1:1 slot is freed.
func (h *Hub) closeSessionLocked(s *Session, reason string) {
	if s.State == protocol.SessionClosed {
		return
	}
	s.State = protocol.SessionClosed
	for _, sd := range []*side{&s.Host, &s.Ctrl} {
		if sd.conn != nil {
			h.sendLocked(sd.conn, protocol.TypeBye, "", protocol.Bye{
				SessionID: s.ID, Reason: reason})
			sd.conn.sessionID = ""
			sd.conn = nil
		}
		sd.nonce = ""
		sd.expiry = time.Time{}
		if h.devSess[sd.deviceID] == s.ID {
			delete(h.devSess, sd.deviceID)
		}
	}
	delete(h.sessions, s.ID)
	h.reportSessionStop(protocol.SessionStopReport{
		SessionID: s.ID, EndedAt: h.clock.Now().UnixMilli(), Reason: reason})
	h.log.Info("session closed", "sessionId", s.ID, "reason", reason)
}

// closeSessionsForDeviceLocked kills every session a device participates in.
func (h *Hub) closeSessionsForDeviceLocked(deviceID, reason string) {
	for _, s := range h.sessions {
		if s.Host.deviceID == deviceID || s.Ctrl.deviceID == deviceID {
			h.closeSessionLocked(s, reason)
		}
	}
}
