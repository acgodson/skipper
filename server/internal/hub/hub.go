// Package hub holds all of rc-signal's live state: which devices are online
// and which sessions exist.
package hub

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/clockx"
	"rc-signal/internal/entitlement"
	"rc-signal/internal/store"
	"rcprotocol"
)

const (
	HeartbeatInterval = protocol.HeartbeatSec * time.Second
	OfflineAfter      = protocol.OfflineAfterSec * time.Second
	SessionTokenTTL   = protocol.SessionTokenTTLSec * time.Second
	PendingTimeout    = protocol.PendingTimeoutSec * time.Second
	NonceTTL          = protocol.NonceTTLSec * time.Second
	AuthTimeout       = protocol.AuthTimeoutSec * time.Second
	TurnCredTTL       = protocol.TurnCredTTLSec * time.Second
)

// TODO: PROTOCOL.md §3.3 keeps a per-host limiter on connect_req attempts as a
// whole in v2. The code-guess limiter it replaced is gone; the attempt limiter
// is not implemented yet, and error{rate_limited} is therefore never sent.

type Options struct {
	Store       *store.Store
	Entitlement entitlement.Entitlement
	Clock       clockx.Clock
	Signer      *auth.Signer
	Logger      *slog.Logger
	TurnSecret  string
	TurnURLs    []string
	StunURLs    []string
}

type Hub struct {
	mu     sync.Mutex
	opt    Options
	clock  clockx.Clock
	log    *slog.Logger
	nextID uint64

	clients  map[uint64]*Client
	byDevice map[string]*Client
	presence map[string]*presenceState
	watchers map[string]map[uint64]*Client
	sessions map[string]*Session
	devSess  map[string]string
}

type presenceState struct {
	online   bool
	since    time.Time
	lastSeen time.Time
}

type Client struct {
	ID uint64

	send  func([]byte)
	close func(code int, msg string)

	deviceID  string
	role      string
	authed    bool
	nonce     []byte
	nonceExp  time.Time
	watches   map[string]struct{}
	lastSeen  time.Time
	connected time.Time
	sessionID string
	badMsgs   int
	closed    bool
}

func (c *Client) DeviceID() string { return c.deviceID }

func New(o Options) *Hub {
	if o.Clock == nil {
		o.Clock = clockx.Real{}
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	return &Hub{
		opt:      o,
		clock:    o.Clock,
		log:      o.Logger,
		clients:  map[uint64]*Client{},
		byDevice: map[string]*Client{},
		presence: map[string]*presenceState{},
		watchers: map[string]map[uint64]*Client{},
		sessions: map[string]*Session{},
		devSess:  map[string]string{},
	}
}

func (h *Hub) Now() time.Time { return h.clock.Now() }

func (h *Hub) AddClient(send func([]byte), closeFn func(code int, msg string)) *Client {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock.Now()
	h.nextID++
	c := &Client{
		ID: h.nextID, send: send, close: closeFn,
		watches: map[string]struct{}{}, lastSeen: now, connected: now,
	}
	h.clients[c.ID] = c
	h.issueChallengeLocked(c)
	return c
}

func (h *Hub) issueChallengeLocked(c *Client) {
	raw, b64, err := auth.NewNonce()
	if err != nil {
		h.sendLocked(c, protocol.TypeError, "", protocol.Error{
			Code: protocol.ErrInternal, Message: "could not generate a challenge"})
		return
	}
	now := h.clock.Now()
	c.nonce, c.nonceExp = raw, now.Add(NonceTTL)
	h.sendLocked(c, protocol.TypeChallenge, "", protocol.Challenge{
		Nonce: b64, ServerTime: now.UnixMilli()})
}

func (h *Hub) RemoveClient(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.removeClientLocked(c)
}

func (h *Hub) removeClientLocked(c *Client) {
	if c.closed {
		return
	}
	c.closed = true
	delete(h.clients, c.ID)
	for dev := range c.watches {
		if m := h.watchers[dev]; m != nil {
			delete(m, c.ID)
			if len(m) == 0 {
				delete(h.watchers, dev)
			}
		}
	}
	c.watches = map[string]struct{}{}
	if c.deviceID != "" && h.byDevice[c.deviceID] == c {
		delete(h.byDevice, c.deviceID)
		h.setPresenceLocked(c.deviceID, false)
	}
	if c.sessionID != "" {
		h.detachLocked(c)
	}
}

func (h *Hub) touchLocked(c *Client) {
	now := h.clock.Now()
	c.lastSeen = now
	if c.deviceID == "" {
		return
	}
	p := h.presence[c.deviceID]
	if p == nil {
		p = &presenceState{}
		h.presence[c.deviceID] = p
	}
	p.lastSeen = now
	if !p.online {
		p.online = true
		p.since = now
		h.pushPresenceLocked(c.deviceID)
	}
}

func (h *Hub) setPresenceLocked(deviceID string, online bool) {
	p := h.presence[deviceID]
	if p == nil {
		p = &presenceState{}
		h.presence[deviceID] = p
	}
	if p.online == online {
		return
	}
	p.online = online
	p.since = h.clock.Now()
	h.pushPresenceLocked(deviceID)
}

func (h *Hub) presenceMsgLocked(deviceID string) protocol.Presence {
	p := h.presence[deviceID]
	if p == nil {
		return protocol.Presence{DeviceID: deviceID, Online: false, Since: 0}
	}
	var since int64
	if !p.since.IsZero() {
		since = p.since.UnixMilli()
	}
	return protocol.Presence{DeviceID: deviceID, Online: p.online, Since: since}
}

func (h *Hub) pushPresenceLocked(deviceID string) {
	msg := h.presenceMsgLocked(deviceID)
	for _, w := range h.watchers[deviceID] {
		h.sendLocked(w, protocol.TypePresence, "", msg)
	}
}

func (h *Hub) IsOnline(deviceID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	p := h.presence[deviceID]
	return p != nil && p.online
}

func (h *Hub) Sweep() {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock.Now()

	for dev, p := range h.presence {
		if p.online && now.Sub(p.lastSeen) > OfflineAfter {
			h.setPresenceLocked(dev, false)
		}
	}

	for id, s := range h.sessions {
		if s.State == protocol.SessionClosed {
			delete(h.sessions, id)
			continue
		}
		if s.State == protocol.SessionPending && now.Sub(s.CreatedAt) > PendingTimeout {
			h.closeSessionLocked(s, protocol.ByeTimeout)
			continue
		}
		if s.expiredLocked(now) {
			h.closeSessionLocked(s, protocol.ByeTimeout)
		}
	}
}

func (h *Hub) Shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, s := range h.sessions {
		h.closeSessionLocked(s, protocol.ByeShutdown)
	}
}

const SessionReportTimeout = 30 * time.Second

func (h *Hub) reportSessionStart(r protocol.SessionStartReport) {
	ent := h.opt.Entitlement
	if ent == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), SessionReportTimeout)
		defer cancel()
		if err := ent.SessionStarted(ctx, r); err != nil {
			h.log.Error("session start report failed", "sessionId", r.SessionID, "err", err)
		}
	}()
}

func (h *Hub) reportSessionStop(r protocol.SessionStopReport) {
	ent := h.opt.Entitlement
	if ent == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), SessionReportTimeout)
		defer cancel()
		if err := ent.SessionStopped(ctx, r); err != nil {
			h.log.Error("session stop report failed", "sessionId", r.SessionID, "err", err)
		}
	}()
}

func (h *Hub) sendLocked(c *Client, typ, re string, payload any) {
	if c == nil || c.closed {
		return
	}
	b, err := protocol.Encode(typ, "", re, h.clock.Now().UnixMilli(), payload)
	if err != nil {
		h.log.Error("encode failed", "type", typ, "err", err)
		return
	}
	c.send(b)
}

func (h *Hub) sendErrLocked(c *Client, re, code, msg string, retryAfterSec int) {
	h.sendLocked(c, protocol.TypeError, re, protocol.Error{
		Code: code, Message: msg, RetryAfterSec: retryAfterSec})
}

func (h *Hub) sendEntitlementErrLocked(c *Client, re, reason, msg string) {
	h.sendLocked(c, protocol.TypeError, re, protocol.Error{
		Code: protocol.ErrEntitlement, Message: msg, Reason: reason})
}
