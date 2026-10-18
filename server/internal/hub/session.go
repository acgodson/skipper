package hub

import (
	"crypto/rand"
	"encoding/hex"
	"time"

	"rc-signal/internal/auth"
	"rcprotocol"
)

// side.unmeteredICE and unmeteredSDP count what this side had relayed before metering began.
type side struct {
	deviceID     string
	pubkey       string
	conn         *Client
	nonce        string
	expiry       time.Time
	epoch        int64
	unmeteredICE int
	unmeteredSDP int
}

// Session.metered turns true when the host relays its first sdp, which it sends
// only after the access code was proved and the owner consented; only then is
// the session reported to rc-api and billed, and only then does it get TURN.
type Session struct {
	ID        string
	State     string
	Host      side
	Ctrl      side
	CreatedAt time.Time
	metered   bool
	meteredAt time.Time
	pakeSent  [protocol.PakeStepLast + 1]bool

	// What the host said about its own route, for measurement only (PROTOCOL.md
	// §2.14.1). Only the host's bye ever writes these; a controller's claim about a
	// host's relay use is discarded, because the host is the party that would pay.
	relayUsed    bool
	bytesRelayed *int64
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

// refuseRelay names why the session may not relay msg from sender now, or returns "".
// Steps 1 and 3 of pake are the controller's and step 2 the host's, each once and in order.
func (s *Session) refuseRelay(msg protocol.Relay, sender *side) string {
	fromHost := sender == &s.Host
	switch m := msg.(type) {
	case protocol.Pake:
		switch {
		case fromHost != (m.Step == 2):
			return "this pake step belongs to the other side"
		case s.pakeSent[m.Step] || m.Step > protocol.PakeStepFirst && !s.pakeSent[m.Step-1]:
			return "pake steps are relayed once each, in order"
		}
	case protocol.ICE:
		if !s.metered && sender.unmeteredICE >= protocol.MaxUnmeteredICEPerSide {
			return "too many candidates before the session is metered"
		}
	case protocol.SDP:
		if !s.metered && !fromHost && sender.unmeteredSDP >= protocol.MaxUnmeteredSDPFromCtrl {
			return "too many descriptions before the session is metered"
		}
	}
	return ""
}

func (s *Session) recordRelay(msg protocol.Relay, sender *side) {
	switch m := msg.(type) {
	case protocol.Pake:
		s.pakeSent[m.Step] = true
	case protocol.ICE:
		if !s.metered {
			sender.unmeteredICE++
		}
	case protocol.SDP:
		if !s.metered {
			sender.unmeteredSDP++
		}
	}
}

func (s *Session) roleOf(deviceID string) string {
	if deviceID == s.Host.deviceID {
		return protocol.RoleHost
	}
	return protocol.RoleController
}

func (s *Session) expiredLocked(now time.Time) bool {
	if s.State == protocol.SessionOpen || s.State == protocol.SessionPending {
		return false
	}
	anyDetached := false
	for _, sd := range []*side{&s.Host, &s.Ctrl} {
		if sd.conn == nil {
			anyDetached = true
			if now.Before(sd.expiry) {
				return false
			}
		}
	}
	return anyDetached
}

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

func (h *Hub) SessionState(id string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.sessions[id]
	if s == nil {
		return ""
	}
	return s.State
}

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
	h.reportStopLocked(s, reason)
	h.log.Info("session closed", "sessionId", s.ID, "reason", reason, "metered", s.metered)
}

// A controller whose process died cannot resume: its session token lived in memory. Its own
// session, with its side detached, would otherwise hold the host's slot as busy until the token
// TTL ran out (§4.2, up to ten minutes). A fresh connect_req from that same controller for that
// same host replaces the dead session instead (§2.9 step 6). A controller that is still attached
// is never displaced this way; one socket per device is enforced at hello.
func (h *Hub) supersedeOwnDetachedSessionLocked(c *Client, hostID string) {
	sid, ok := h.devSess[c.deviceID]
	if !ok {
		return
	}
	s := h.sessions[sid]
	if s == nil || s.State == protocol.SessionClosed {
		return
	}
	if s.Ctrl.deviceID != c.deviceID || s.Ctrl.conn != nil || s.Host.deviceID != hostID {
		return
	}
	h.log.Info("session replaced by a fresh connect_req from its own detached controller",
		"sessionId", s.ID, "controller", c.deviceID, "host", hostID)
	h.closeSessionLocked(s, protocol.ByeReplaced)
}

func (h *Hub) closeSessionsForDeviceLocked(deviceID, reason string) int {
	closed := 0
	for _, s := range h.sessions {
		if s.Host.deviceID == deviceID || s.Ctrl.deviceID == deviceID {
			h.closeSessionLocked(s, reason)
			closed++
		}
	}
	return closed
}

// CloseSessionsForDevice ends every live session the device takes part in; it is
// what rc-api asks for when the device is unlinked from its account (API.md §3.6).
func (h *Hub) CloseSessionsForDevice(deviceID, reason string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	closed := h.closeSessionsForDeviceLocked(deviceID, reason)
	if closed > 0 {
		h.log.Info("sessions closed for device", "deviceId", deviceID, "reason", reason, "closed", closed)
	}
	return closed
}

// displaceStaleBindingLocked ends everything the hub holds for deviceID under a
// key other than pubkey: a registry restore just gave the id back to pubkey.
func (h *Hub) displaceStaleBindingLocked(deviceID, pubkey string) {
	for _, s := range h.sessions {
		for _, sd := range []*side{&s.Host, &s.Ctrl} {
			if sd.deviceID == deviceID && sd.pubkey != pubkey {
				h.closeSessionLocked(s, protocol.ByeDisplaced)
				break
			}
		}
	}
	if old := h.byDevice[deviceID]; old != nil && old.pubkey != pubkey {
		h.sendErrLocked(old, "", protocol.ErrDisplaced, "this device id was restored to its certified key", 0)
		h.dropClientLocked(old, 1000, "displaced")
		h.log.Info("stale device binding displaced", "deviceId", deviceID)
	}
}
