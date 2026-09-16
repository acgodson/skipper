// Package hub holds all of rc-signal's live state: which devices are online,
// which sessions exist, and the access-code failure counters. It is transport
// agnostic on purpose — the WebSocket layer hands it opaque frames and a
// send function, which is what makes it directly testable with a fake clock.
//
// Concurrency: one mutex guards everything. This is a two-device system; the
// contention does not exist.
package hub

import (
	"log/slog"
	"sync"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/clockx"
	"rc-signal/internal/store"
	"rcprotocol"
)

// Timing constants, mirrored in PROTOCOL.md.
const (
	HeartbeatInterval = protocol.HeartbeatSec * time.Second
	OfflineAfter      = protocol.OfflineAfterSec * time.Second
	SessionTokenTTL   = protocol.SessionTokenTTLSec * time.Second
	PendingTimeout    = protocol.PendingTimeoutSec * time.Second
	NonceTTL          = protocol.NonceTTLSec * time.Second
	AuthTimeout       = protocol.AuthTimeoutSec * time.Second
	TurnCredTTL       = protocol.TurnCredTTLSec * time.Second

	// Access-code rate limiting, PROTOCOL.md §3.3.
	FailWindow    = 15 * time.Minute
	FailThreshold = 5
	LockoutBase   = time.Minute
	LockoutMax    = 60 * time.Minute
)

// Options configures a Hub.
type Options struct {
	Store      *store.Store
	Clock      clockx.Clock
	Signer     *auth.Signer
	Logger     *slog.Logger
	TurnSecret string
	TurnURLs   []string
	StunURLs   []string
}

// Hub is the live server state.
type Hub struct {
	mu     sync.Mutex
	opt    Options
	clock  clockx.Clock
	log    *slog.Logger
	nextID uint64

	clients  map[uint64]*Client
	byDevice map[string]*Client            // authenticated connection per device
	presence map[string]*presenceState     // deviceId -> presence, never pruned
	watchers map[string]map[uint64]*Client // watched deviceId -> watchers
	sessions map[string]*Session
	devSess  map[string]string // deviceId -> sessionId (at most one)
	fails    map[string]*failState
}

type presenceState struct {
	online   bool
	since    time.Time // when this online/offline state began
	lastSeen time.Time
}

// Client is one WebSocket connection as the hub sees it.
type Client struct {
	ID uint64

	send  func([]byte)               // non-blocking enqueue
	close func(code int, msg string) // ask the transport to close

	// All fields below are guarded by Hub.mu.
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

// DeviceID returns the authenticated device id, or "" before hello.
func (c *Client) DeviceID() string { return c.deviceID }

// New builds a Hub.
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
		fails:    map[string]*failState{},
	}
}

// Now exposes the hub's clock, for the transport layer's timeouts.
func (h *Hub) Now() time.Time { return h.clock.Now() }

// AddClient registers a new connection and immediately issues its challenge.
// send must not block; close asks the transport to terminate the socket.
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

// RemoveClient tears a connection down: presence goes offline immediately,
// watches are dropped, and any attached session is detached (but NOT closed —
// that is the whole point of the resume path).
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

// ---------------------------------------------------------------------------
// Presence
// ---------------------------------------------------------------------------

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

// IsOnline reports the current presence of a device. Exported for tests.
func (h *Hub) IsOnline(deviceID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	p := h.presence[deviceID]
	return p != nil && p.online
}

// ---------------------------------------------------------------------------
// Sweep
// ---------------------------------------------------------------------------

// Sweep applies every time-based transition: presence timeouts, pending-session
// timeouts and session-token expiry. The server calls it on a ticker; tests
// call it directly after advancing the fake clock.
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

// Shutdown closes every session with reason "shutdown" and notifies peers.
func (h *Hub) Shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, s := range h.sessions {
		h.closeSessionLocked(s, protocol.ByeShutdown)
	}
}

// ---------------------------------------------------------------------------
// Rate limiting (PROTOCOL.md §3.3)
// ---------------------------------------------------------------------------

type failState struct {
	fails       []time.Time
	lockedUntil time.Time
}

func (f *failState) prune(now time.Time) {
	keep := f.fails[:0]
	for _, t := range f.fails {
		if now.Sub(t) < FailWindow {
			keep = append(keep, t)
		}
	}
	f.fails = keep
}

// lockoutLocked returns the seconds remaining, or 0 if not locked out.
func (h *Hub) lockoutLocked(deviceID string, now time.Time) int {
	f := h.fails[deviceID]
	if f == nil {
		return 0
	}
	f.prune(now)
	if now.Before(f.lockedUntil) {
		d := f.lockedUntil.Sub(now)
		secs := int((d + time.Second - 1) / time.Second)
		if secs < 1 {
			secs = 1
		}
		return secs
	}
	return 0
}

func (h *Hub) recordFailLocked(deviceID string, now time.Time) {
	f := h.fails[deviceID]
	if f == nil {
		f = &failState{}
		h.fails[deviceID] = f
	}
	f.prune(now)
	f.fails = append(f.fails, now)
	if n := len(f.fails); n >= FailThreshold {
		shift := uint(n - FailThreshold)
		if shift > 16 {
			shift = 16
		}
		d := LockoutBase << shift
		if d > LockoutMax || d <= 0 {
			d = LockoutMax
		}
		f.lockedUntil = now.Add(d)
	}
}

func (h *Hub) clearFailsLocked(deviceID string) { delete(h.fails, deviceID) }

// FailCount returns the number of in-window failures for a device (test hook).
func (h *Hub) FailCount(deviceID string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	f := h.fails[deviceID]
	if f == nil {
		return 0
	}
	f.prune(h.clock.Now())
	return len(f.fails)
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

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
