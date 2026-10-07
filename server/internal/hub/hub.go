// Package hub holds all of rc-signal's live state: which devices are online
// and which sessions exist.
package hub

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/clockx"
	"rc-signal/internal/entitlement"
	"rc-signal/internal/ratelimit"
	"rc-signal/internal/registry"
	"rc-signal/internal/reports"
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

var (
	ruleConnectCtrlMin  = ratelimit.Rule{Name: "connect_ctrl_min", Limit: protocol.ConnectPerControllerPerMin, Window: time.Minute}
	ruleConnectCtrlHour = ratelimit.Rule{Name: "connect_ctrl_hour", Limit: protocol.ConnectPerControllerPerHour, Window: time.Hour}
	ruleConnectHostMin  = ratelimit.Rule{Name: "connect_host_min", Limit: protocol.ConnectPerHostPerMin, Window: time.Minute}
	ruleConnectHostHour = ratelimit.Rule{Name: "connect_host_hour", Limit: protocol.ConnectPerHostPerHour, Window: time.Hour}
	ruleConnectPairMin  = ratelimit.Rule{Name: "connect_pair_min", Limit: protocol.ConnectPerPairPerMin, Window: time.Minute}
	ruleConnectPairHour = ratelimit.Rule{Name: "connect_pair_hour", Limit: protocol.ConnectPerPairPerHour, Window: time.Hour}
)

// KnownPairsMax bounds the in-memory cache of pairs that had a metered session; the durable
// record is the entitlement backend's.
const KnownPairsMax = 100000

// Options.RegistersPerIPPerHour and ConnectsPerIPPerMin default to the protocol limits;
// local test rigs that drive many devices from one address raise them.
type Options struct {
	Registry              registry.Registry
	Entitlement           entitlement.Entitlement
	Clock                 clockx.Clock
	Signer                *auth.Signer
	Logger                *slog.Logger
	TurnSecret            string
	TurnURLs              []string
	StunURLs              []string
	Reports               reports.Options
	RegistersPerIPPerHour int
	ConnectsPerIPPerMin   int
}

type Hub struct {
	mu           sync.Mutex
	opt          Options
	clock        clockx.Clock
	log          *slog.Logger
	nextID       uint64
	limiter      *ratelimit.Limiter
	registerRule ratelimit.Rule
	connectRule  ratelimit.Rule
	reports      *reports.Queue

	clients    map[uint64]*Client
	byDevice   map[string]*Client
	presence   map[string]*presenceState
	watchers   map[string]map[uint64]*Client
	sessions   map[string]*Session
	devSess    map[string]string
	knownPairs map[string]struct{}
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

	ip        string
	deviceID  string
	pubkey    string
	role      string
	authed    bool
	registers int
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
	if o.RegistersPerIPPerHour <= 0 {
		o.RegistersPerIPPerHour = protocol.RegistersPerIPPerHour
	}
	if o.ConnectsPerIPPerMin <= 0 {
		o.ConnectsPerIPPerMin = protocol.ConnectPerIPPerMin
	}
	h := &Hub{
		opt:          o,
		clock:        o.Clock,
		log:          o.Logger,
		limiter:      ratelimit.New(),
		registerRule: ratelimit.Rule{Name: "register_ip", Limit: float64(o.RegistersPerIPPerHour), Window: time.Hour},
		connectRule:  ratelimit.Rule{Name: "connect_ip_min", Limit: float64(o.ConnectsPerIPPerMin), Window: time.Minute},
		clients:      map[uint64]*Client{},
		byDevice:     map[string]*Client{},
		presence:     map[string]*presenceState{},
		watchers:     map[string]map[uint64]*Client{},
		sessions:     map[string]*Session{},
		devSess:      map[string]string{},
		knownPairs:   map[string]struct{}{},
	}
	if o.Entitlement != nil {
		ro := o.Reports
		if ro.Logger == nil {
			ro.Logger = o.Logger
		}
		ro.OnDenied = h.endDeniedSession
		h.reports = reports.New(o.Entitlement, ro)
	}
	return h
}

func (h *Hub) Now() time.Time { return h.clock.Now() }

// AddClient registers a socket; ip is the resolved client address the per-IP limits key on.
func (h *Hub) AddClient(ip string, send func([]byte), closeFn func(code int, msg string)) *Client {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock.Now()
	h.nextID++
	c := &Client{
		ID: h.nextID, send: send, close: closeFn, ip: ip,
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

func (h *Hub) dropClientLocked(c *Client, code int, reason string) {
	h.removeClientLocked(c)
	c.close(code, reason)
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

	for _, c := range h.clients {
		if !c.authed && now.Sub(c.connected) >= AuthTimeout {
			h.log.Info("closing unauthenticated connection")
			h.dropClientLocked(c, 1008, "auth_timeout")
		}
	}

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

// LiveMeteredSessions lists the sessions rc-api has been told about and that are still open.
func (h *Hub) LiveMeteredSessions() protocol.InternalLiveSessions {
	h.mu.Lock()
	defer h.mu.Unlock()
	ids := []string{}
	for id, s := range h.sessions {
		if s.metered && s.State != protocol.SessionClosed {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return protocol.InternalLiveSessions{SessionIDs: ids, ServerTime: h.clock.Now().UnixMilli()}
}

func (h *Hub) Shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, s := range h.sessions {
		h.closeSessionLocked(s, protocol.ByeShutdown)
	}
}

// FlushReports waits, bounded by ctx, for queued session reports to be delivered.
func (h *Hub) FlushReports(ctx context.Context) {
	if h.reports != nil {
		h.reports.Close(ctx)
	}
}

func (h *Hub) endDeniedSession(sessionID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if s := h.sessions[sessionID]; s != nil {
		h.endUnregisteredSessionLocked(s)
	}
}

// endUnregisteredSessionLocked drops a session accounting never took a start report
// for. It un-meters first: without a billing row the session is not a metered
// session, so it must not be reported as one, and the stop report that would settle
// it has nothing to settle (review5 H7).
func (h *Hub) endUnregisteredSessionLocked(s *Session) {
	s.metered = false
	h.closeSessionLocked(s, protocol.ByeError)
}

// reportStartLocked reports the session; false means accounting will never hear
// about it, so the caller must not let it run.
func (h *Hub) reportStartLocked(s *Session) bool {
	if h.reports == nil {
		return true
	}
	return h.reports.Started(protocol.SessionStartReport{
		SessionID: s.ID, HostDeviceID: s.Host.deviceID, ControllerDeviceID: s.Ctrl.deviceID,
		StartedAt: s.meteredAt.UnixMilli(),
	})
}

func (h *Hub) reportStopLocked(s *Session, reason string) {
	if h.reports == nil || !s.metered {
		return
	}
	h.reports.Stopped(protocol.SessionStopReport{
		SessionID: s.ID, EndedAt: h.clock.Now().UnixMilli(), Reason: reason,
		RelayUsed: s.relayUsed, BytesRelayed: s.bytesRelayed})
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

// takeLocked charges the limiter and answers error{rate_limited} when it refuses.
func (h *Hub) takeLocked(c *Client, re string, charges ...ratelimit.Charge) bool {
	return h.limitedLocked(c, re, h.limiter.Take, charges)
}

// roomLocked is takeLocked without the charge.
func (h *Hub) roomLocked(c *Client, re string, charges ...ratelimit.Charge) bool {
	return h.limitedLocked(c, re, h.limiter.Room, charges)
}

func (h *Hub) limitedLocked(c *Client, re string, check func(time.Time, ...ratelimit.Charge) (bool, int), charges []ratelimit.Charge) bool {
	ok, wait := check(h.clock.Now(), charges...)
	if !ok {
		h.sendErrLocked(c, re, protocol.ErrRateLimited, "too many attempts; retry later", wait)
	}
	return ok
}

func pairKey(hostDeviceID, controllerDeviceID string) string {
	return hostDeviceID + "|" + controllerDeviceID
}

func (h *Hub) rememberPairLocked(hostDeviceID, controllerDeviceID string) {
	if len(h.knownPairs) >= KnownPairsMax {
		h.knownPairs = map[string]struct{}{}
	}
	h.knownPairs[pairKey(hostDeviceID, controllerDeviceID)] = struct{}{}
}

// knownPair consults the in-memory cache, then the durable record; a failed lookup counts as unknown.
func (h *Hub) knownPair(hostDeviceID, controllerDeviceID string) bool {
	h.mu.Lock()
	_, cached := h.knownPairs[pairKey(hostDeviceID, controllerDeviceID)]
	h.mu.Unlock()
	if cached {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), entitlement.CheckTimeout)
	defer cancel()
	known, err := h.opt.Entitlement.KnownPair(ctx, hostDeviceID, controllerDeviceID)
	if err != nil {
		h.log.Warn("known-pair lookup failed; charging the host budget", "host", hostDeviceID, "err", err)
		return false
	}
	if known {
		h.mu.Lock()
		h.rememberPairLocked(hostDeviceID, controllerDeviceID)
		h.mu.Unlock()
	}
	return known
}
