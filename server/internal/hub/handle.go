package hub

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/entitlement"
	"rc-signal/internal/registry"
	"rcprotocol"
)

func (h *Hub) Handle(c *Client, raw []byte) {

	var probe struct {
		V    int    `json:"v"`
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		h.mu.Lock()
		h.sendErrLocked(c, "", protocol.ErrBadRequest, "malformed JSON", 0)
		h.mu.Unlock()
		return
	}
	if probe.V != protocol.Version {
		h.mu.Lock()
		h.sendErrLocked(c, probe.ID, protocol.ErrUnsupportedVersion, "unsupported protocol version", 0)
		h.mu.Unlock()
		c.close(1002, "unsupported_version")
		return
	}
	e, err := protocol.Decode(raw)
	if err != nil {
		h.mu.Lock()
		h.sendErrLocked(c, probe.ID, protocol.ErrBadRequest, "malformed envelope", 0)
		h.mu.Unlock()
		return
	}

	switch e.Type {
	case protocol.TypeConnectReq:
		h.handleConnectReq(c, e)
		return
	case protocol.TypeRegister:
		h.handleRegister(c, e)
		return
	case protocol.TypeHello:
		h.handleHello(c, e)
		return
	case protocol.TypeRefreshCode:
		h.handleRefresh(c, e)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	h.handleLocked(c, e)
}

func (h *Hub) handleLocked(c *Client, e protocol.Envelope) {
	if !h.acceptAuthedLocked(c, e) {
		return
	}

	switch e.Type {
	case protocol.TypeHeartbeat:
		h.sendLocked(c, protocol.TypeHeartbeatOK, e.ID,
			protocol.HeartbeatOK{ServerTime: h.clock.Now().UnixMilli()})
	case protocol.TypeWatch:
		h.handleWatchLocked(c, e)
	case protocol.TypeUnwatch:
		h.handleUnwatchLocked(c, e)
	case protocol.TypeResume:
		h.handleResumeLocked(c, e)
	case protocol.TypeRenew:
		h.handleRenewLocked(c, e)
	case protocol.TypeSDP, protocol.TypeICE, protocol.TypePake:
		h.handleRelayLocked(c, e)
	case protocol.TypeBye:
		h.handleByeLocked(c, e)
	default:
		h.sendErrLocked(c, e.ID, protocol.ErrUnsupported, "unknown message type", 0)
	}
}

func (h *Hub) acceptAuthedLocked(c *Client, e protocol.Envelope) bool {
	if c.closed {
		return false
	}
	if !c.authed {
		c.badMsgs++
		h.sendErrLocked(c, e.ID, protocol.ErrUnauthenticated, "authenticate with hello first", 0)
		if c.badMsgs >= 3 {
			c.close(1008, "unauthenticated")
		}
		return false
	}
	h.touchLocked(c)
	return true
}

func (h *Hub) acceptUnauthedLocked(c *Client, e protocol.Envelope) bool {
	if c.closed {
		return false
	}
	if c.authed {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "already authenticated", 0)
		return false
	}
	return true
}

func registryContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), registry.CallBudget)
}

const RegistryRetryAfterSec = 5

func (h *Hub) sendRegistryErrLocked(c *Client, re, what string, err error) {
	if errors.Is(err, registry.ErrUnavailable) {
		h.log.Error(what+" failed: device registry unavailable", "err", err)
		h.sendErrLocked(c, re, protocol.APIErrUnavailable,
			"the device registry is unavailable; retry shortly", RegistryRetryAfterSec)
		return
	}
	h.log.Error(what+" failed", "err", err)
	h.sendErrLocked(c, re, protocol.ErrInternal, what+" failed", 0)
}

func (h *Hub) checkNonceLocked(c *Client, pubkey, sig string) bool {
	now := h.clock.Now()
	if len(c.nonce) == 0 || !now.Before(c.nonceExp) {
		return false
	}
	nonce := c.nonce
	c.nonce = nil
	return auth.VerifyDeviceSig(pubkey, sig, nonce) == nil
}

func (h *Hub) acceptRegisterLocked(c *Client, e protocol.Envelope) (protocol.Register, bool) {
	var p protocol.Register
	if !h.acceptUnauthedLocked(c, e) {
		return p, false
	}
	if err := protocol.Unmarshal(e, &p); err != nil || p.Pubkey == "" || p.Sig == "" {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "register requires pubkey and sig", 0)
		return p, false
	}
	if p.Code != (protocol.CodeVerifier{}) {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "register must not carry a code verifier", 0)
		return p, false
	}
	if len(p.Label) > protocol.MaxLabelLen {
		p.Label = p.Label[:protocol.MaxLabelLen]
	}
	if !h.checkNonceLocked(c, p.Pubkey, p.Sig) {
		h.sendErrLocked(c, e.ID, protocol.ErrBadSignature, "challenge signature rejected", 0)
		h.issueChallengeLocked(c)
		return p, false
	}
	return p, true
}

func (h *Hub) handleRegister(c *Client, e protocol.Envelope) {
	h.mu.Lock()
	p, ok := h.acceptRegisterLocked(c, e)
	h.mu.Unlock()
	if !ok {
		return
	}

	ctx, cancel := registryContext()
	dev, existing, err := h.opt.Registry.Register(ctx, p.Pubkey, p.Label)
	cancel()

	h.mu.Lock()
	defer h.mu.Unlock()
	if c.closed {
		return
	}
	if err != nil {
		h.sendRegistryErrLocked(c, e.ID, "register", err)
		h.issueChallengeLocked(c)
		return
	}
	h.log.Info("device registered", "deviceId", dev.DeviceID, "existing", existing)
	h.sendLocked(c, protocol.TypeRegisterOK, e.ID, protocol.RegisterOK{
		DeviceID: dev.DeviceID, Existing: existing})

	h.issueChallengeLocked(c)
}

func (h *Hub) acceptHelloLocked(c *Client, e protocol.Envelope) (protocol.Hello, bool) {
	var p protocol.Hello
	if !h.acceptUnauthedLocked(c, e) {
		return p, false
	}
	if err := protocol.Unmarshal(e, &p); err != nil {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "malformed hello", 0)
		return p, false
	}
	if !protocol.ValidDeviceID(p.DeviceID) {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "deviceId must be 9 digits", 0)
		return p, false
	}
	if p.Role != protocol.RoleHost && p.Role != protocol.RoleController {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "role must be host or controller", 0)
		return p, false
	}
	return p, true
}

func (h *Hub) handleHello(c *Client, e protocol.Envelope) {
	h.mu.Lock()
	p, ok := h.acceptHelloLocked(c, e)
	h.mu.Unlock()
	if !ok {
		return
	}

	ctx, cancel := registryContext()
	dev, err := h.opt.Registry.Lookup(ctx, p.DeviceID)
	cancel()

	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.acceptUnauthedLocked(c, e) {
		return
	}
	if errors.Is(err, registry.ErrNotFound) {
		h.sendErrLocked(c, e.ID, protocol.ErrUnknownDevice, "unknown device", 0)
		h.issueChallengeLocked(c)
		return
	}
	if err != nil {
		h.sendRegistryErrLocked(c, e.ID, "device lookup", err)
		return
	}

	if p.Pubkey != dev.Pubkey || !h.checkNonceLocked(c, p.Pubkey, p.Sig) {
		h.sendErrLocked(c, e.ID, protocol.ErrBadSignature, "challenge signature rejected", 0)
		h.issueChallengeLocked(c)
		return
	}

	if old := h.byDevice[p.DeviceID]; old != nil && old != c {
		h.sendErrLocked(old, "", protocol.ErrDisplaced, "another connection authenticated as this device", 0)
		h.removeClientLocked(old)
		old.close(1000, "displaced")
	}

	c.authed = true
	c.deviceID = dev.DeviceID
	c.role = p.Role
	c.nonce = nil
	h.byDevice[dev.DeviceID] = c
	h.touchLocked(c)

	hello := protocol.HelloOK{
		DeviceID:           dev.DeviceID,
		ServerTime:         h.clock.Now().UnixMilli(),
		ICEServers:         h.iceServersLocked(dev.DeviceID),
		HeartbeatSec:       protocol.HeartbeatSec,
		OfflineAfterSec:    protocol.OfflineAfterSec,
		SessionTokenTTLSec: protocol.SessionTokenTTLSec,
	}
	if sid, live := h.devSess[dev.DeviceID]; live {
		if s := h.sessions[sid]; s != nil && s.State != protocol.SessionClosed {
			hello.ActiveSessionID = sid
		}
	}
	h.sendLocked(c, protocol.TypeHelloOK, e.ID, hello)
	h.log.Info("device authenticated", "deviceId", dev.DeviceID, "role", p.Role,
		"activeSessionId", hello.ActiveSessionID)
}

func (h *Hub) iceServersLocked(deviceID string) []protocol.ICEServer {
	out := []protocol.ICEServer{}
	if len(h.opt.StunURLs) > 0 {
		out = append(out, protocol.ICEServer{URLs: append([]string{}, h.opt.StunURLs...)})
	}
	if h.opt.TurnSecret != "" && len(h.opt.TurnURLs) > 0 {
		user, cred, exp := auth.TurnCreds(h.opt.TurnSecret, deviceID, h.clock.Now(), TurnCredTTL)
		out = append(out, protocol.ICEServer{
			URLs:       append([]string{}, h.opt.TurnURLs...),
			Username:   user,
			Credential: cred,
			ExpiresAt:  exp.UnixMilli(),
		})
	}
	return out
}

func (h *Hub) handleWatchLocked(c *Client, e protocol.Envelope) {
	var p protocol.Watch
	if err := protocol.Unmarshal(e, &p); err != nil || !protocol.ValidDeviceID(p.DeviceID) {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "watch requires a 9-digit deviceId", 0)
		return
	}
	if _, dup := c.watches[p.DeviceID]; !dup && len(c.watches) >= protocol.MaxWatches {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "too many watches", 0)
		return
	}
	c.watches[p.DeviceID] = struct{}{}
	m := h.watchers[p.DeviceID]
	if m == nil {
		m = map[uint64]*Client{}
		h.watchers[p.DeviceID] = m
	}
	m[c.ID] = c
	h.sendLocked(c, protocol.TypeWatchOK, e.ID, protocol.WatchOK{DeviceID: p.DeviceID})
	h.sendLocked(c, protocol.TypePresence, "", h.presenceMsgLocked(p.DeviceID))
}

func (h *Hub) handleUnwatchLocked(c *Client, e protocol.Envelope) {
	var p protocol.Unwatch
	if err := protocol.Unmarshal(e, &p); err != nil {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "malformed unwatch", 0)
		return
	}
	delete(c.watches, p.DeviceID)
	if m := h.watchers[p.DeviceID]; m != nil {
		delete(m, c.ID)
		if len(m) == 0 {
			delete(h.watchers, p.DeviceID)
		}
	}
	h.sendLocked(c, protocol.TypeUnwatchOK, e.ID, protocol.UnwatchOK{DeviceID: p.DeviceID})
}

func (h *Hub) handleConnectReq(c *Client, e protocol.Envelope) {
	var p protocol.ConnectReq
	if err := protocol.Unmarshal(e, &p); err != nil {
		h.mu.Lock()
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "malformed connect_req", 0)
		h.mu.Unlock()
		return
	}

	h.mu.Lock()
	if !c.authed {
		h.sendErrLocked(c, e.ID, protocol.ErrUnauthenticated, "authenticate with hello first", 0)
		h.mu.Unlock()
		return
	}
	h.touchLocked(c)

	if !protocol.ValidDeviceID(p.DeviceID) {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "connect_req requires a 9-digit deviceId", 0)
		h.mu.Unlock()
		return
	}
	if p.AccessCode != "" {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "connect_req must not carry an access code", 0)
		h.mu.Unlock()
		return
	}
	if p.DeviceID == c.deviceID {
		h.sendErrLocked(c, e.ID, protocol.ErrSelfConnect, "cannot connect to yourself", 0)
		h.mu.Unlock()
		return
	}
	ctrlID := c.deviceID
	h.mu.Unlock()

	host, ctrl, err := h.lookupPair(p.DeviceID, ctrlID)

	h.mu.Lock()
	if c.closed {
		h.mu.Unlock()
		return
	}
	if errors.Is(err, registry.ErrNotFound) {
		h.sendErrLocked(c, e.ID, protocol.ErrUnknownDevice, "unknown device", 0)
		h.mu.Unlock()
		return
	}
	if err != nil {
		h.sendRegistryErrLocked(c, e.ID, "device lookup", err)
		h.mu.Unlock()
		return
	}
	if h.byDevice[p.DeviceID] == nil {
		h.sendErrLocked(c, e.ID, protocol.ErrOffline, "host is offline", 0)
		h.mu.Unlock()
		return
	}
	if h.hasLiveSessionLocked(p.DeviceID) {
		h.sendErrLocked(c, e.ID, protocol.ErrBusy, "host already has an active session", 0)
		h.mu.Unlock()
		return
	}
	h.mu.Unlock()

	decision, err := h.checkEntitlement(p.DeviceID)

	h.mu.Lock()
	defer h.mu.Unlock()
	if c.closed || c.deviceID != ctrlID {
		return
	}
	if err != nil {
		h.log.Error("entitlement check failed", "deviceId", p.DeviceID, "err", err)
		h.sendErrLocked(c, e.ID, protocol.ErrInternal, "entitlement check failed", 0)
		return
	}
	if !decision.Allow {
		h.log.Info("connect_req denied", "deviceId", p.DeviceID, "reason", decision.Reason)
		h.sendEntitlementErrLocked(c, e.ID, decision.Reason, "the host's account may not open a session")
		return
	}
	now := h.clock.Now()

	hostConn := h.byDevice[p.DeviceID]
	if hostConn == nil {
		h.sendErrLocked(c, e.ID, protocol.ErrOffline, "host is offline", 0)
		return
	}
	if h.hasLiveSessionLocked(p.DeviceID) {
		h.sendErrLocked(c, e.ID, protocol.ErrBusy, "host already has an active session", 0)
		return
	}
	if h.hasLiveSessionLocked(c.deviceID) {
		h.sendErrLocked(c, e.ID, protocol.ErrBusy, "controller already has an active session", 0)
		return
	}

	sid, err := newSessionID()
	if err != nil {
		h.sendErrLocked(c, e.ID, protocol.ErrInternal, "could not create session", 0)
		return
	}
	s := &Session{
		ID: sid, State: protocol.SessionPending, CreatedAt: now,
		Host: side{deviceID: host.DeviceID, epoch: host.CodeEpoch},
		Ctrl: side{deviceID: ctrl.DeviceID, epoch: ctrl.CodeEpoch},
	}
	h.sessions[sid] = s
	h.devSess[p.DeviceID] = sid
	h.devSess[c.deviceID] = sid

	ctrlTok, ctrlExp, err1 := h.issueTokenLocked(s, &s.Ctrl, now)
	hostTok, hostExp, err2 := h.issueTokenLocked(s, &s.Host, now)
	if err1 != nil || err2 != nil {
		h.closeSessionLocked(s, protocol.ByeError)
		h.sendErrLocked(c, e.ID, protocol.ErrInternal, "could not mint session tokens", 0)
		return
	}

	h.attachLocked(s, &s.Ctrl, c)
	h.attachLocked(s, &s.Host, hostConn)

	h.sendLocked(c, protocol.TypeConnectOK, e.ID, protocol.ConnectOK{
		SessionID: sid, SessionToken: ctrlTok, ExpiresAt: ctrlExp.UnixMilli(),
		TTLSec: protocol.SessionTokenTTLSec, HostDeviceID: p.DeviceID,
		ControllerDeviceID: c.deviceID,
		HostPubkey:         host.Pubkey,
	})
	h.sendLocked(hostConn, protocol.TypeSessionStart, "", protocol.SessionStart{
		ConnectOK: protocol.ConnectOK{
			SessionID: sid, SessionToken: hostTok, ExpiresAt: hostExp.UnixMilli(),
			TTLSec: protocol.SessionTokenTTLSec, HostDeviceID: p.DeviceID,
			ControllerDeviceID: c.deviceID,
			HostPubkey:         host.Pubkey,
		},
		ControllerPubkey: ctrl.Pubkey,
	})
	h.reportSessionStart(protocol.SessionStartReport{
		SessionID: sid, HostDeviceID: p.DeviceID, ControllerDeviceID: c.deviceID,
		StartedAt: now.UnixMilli(),
	})
	h.log.Info("session opened", "sessionId", sid, "host", p.DeviceID, "controller", c.deviceID)
}

func (h *Hub) checkEntitlement(hostDeviceID string) (entitlement.Decision, error) {
	if h.opt.Entitlement == nil {
		return entitlement.Decision{}, errors.New("no entitlement provider configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), entitlement.CheckTimeout)
	defer cancel()
	return h.opt.Entitlement.Check(ctx, hostDeviceID)
}

func (h *Hub) hasLiveSessionLocked(deviceID string) bool {
	sid, ok := h.devSess[deviceID]
	if !ok {
		return false
	}
	s := h.sessions[sid]
	return s != nil && s.State != protocol.SessionClosed
}

func (h *Hub) lookupPair(hostID, ctrlID string) (host, ctrl registry.Device, err error) {
	ctx, cancel := registryContext()
	defer cancel()
	host, err = h.opt.Registry.Lookup(ctx, hostID)
	if err != nil {
		return host, ctrl, err
	}
	ctrl, err = h.opt.Registry.Lookup(ctx, ctrlID)
	if errors.Is(err, registry.ErrNotFound) {
		err = errors.New("the authenticated controller is missing from the registry")
	}
	return host, ctrl, err
}

func (h *Hub) handleResumeLocked(c *Client, e protocol.Envelope) {
	var p protocol.Resume
	if err := protocol.Unmarshal(e, &p); err != nil || p.SessionID == "" || p.SessionToken == "" {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "resume requires sessionId and sessionToken", 0)
		return
	}
	now := h.clock.Now()
	s, sd, errCode := h.verifyTokenLocked(c.deviceID, p.SessionID, p.SessionToken, now)
	if errCode != "" {
		h.log.Warn("resume rejected", "deviceId", c.deviceID, "sessionId", p.SessionID, "code", errCode)
		h.sendErrLocked(c, e.ID, errCode, "resume rejected", 0)
		return
	}
	if sd.conn != nil && sd.conn != c {
		h.sendErrLocked(c, e.ID, protocol.ErrBusy, "another connection holds this session side", 0)
		return
	}
	h.attachLocked(s, sd, c)
	tok, exp, err := h.issueTokenLocked(s, sd, now)
	if err != nil {
		h.sendErrLocked(c, e.ID, protocol.ErrInternal, "could not mint session token", 0)
		return
	}
	peer := s.peerOf(c.deviceID)
	h.sendLocked(c, protocol.TypeResumeOK, e.ID, protocol.ResumeOK{
		SessionID: s.ID, SessionToken: tok, ExpiresAt: exp.UnixMilli(),
		TTLSec: protocol.SessionTokenTTLSec, PeerAttached: peer != nil && peer.conn != nil,
		Role: s.roleOf(c.deviceID),
	})
	h.log.Info("session resumed", "sessionId", s.ID, "deviceId", c.deviceID, "state", s.State)
}

func (h *Hub) handleRenewLocked(c *Client, e protocol.Envelope) {
	var p protocol.Renew
	if err := protocol.Unmarshal(e, &p); err != nil || p.SessionID == "" || p.SessionToken == "" {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "renew requires sessionId and sessionToken", 0)
		return
	}
	now := h.clock.Now()
	s, sd, errCode := h.verifyTokenLocked(c.deviceID, p.SessionID, p.SessionToken, now)
	if errCode != "" {
		h.sendErrLocked(c, e.ID, errCode, "renew rejected", 0)
		return
	}
	if sd.conn != c {
		h.sendErrLocked(c, e.ID, protocol.ErrNoSession, "connection is not attached to this session", 0)
		return
	}
	tok, exp, err := h.issueTokenLocked(s, sd, now)
	if err != nil {
		h.sendErrLocked(c, e.ID, protocol.ErrInternal, "could not mint session token", 0)
		return
	}
	h.sendLocked(c, protocol.TypeRenewOK, e.ID, protocol.RenewOK{
		SessionID: s.ID, SessionToken: tok, ExpiresAt: exp.UnixMilli(),
		TTLSec: protocol.SessionTokenTTLSec,
	})
}

func (h *Hub) handleRelayLocked(c *Client, e protocol.Envelope) {
	var meta struct {
		SessionID string `json:"sessionId"`
		Payload   string `json:"payload"`
	}
	if err := json.Unmarshal(e.Payload, &meta); err != nil || meta.SessionID == "" {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "relay requires sessionId", 0)
		return
	}
	if e.Type == protocol.TypePake && len(meta.Payload) > protocol.MaxPakePayloadBytes {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "pake payload is too large", 0)
		return
	}
	s := h.sessions[meta.SessionID]
	if s == nil || s.State == protocol.SessionClosed || c.sessionID != meta.SessionID {
		h.sendErrLocked(c, e.ID, protocol.ErrNoSession, "not attached to that session", 0)
		return
	}
	peer := s.peerOf(c.deviceID)
	if peer == nil || peer.conn == nil {
		h.sendErrLocked(c, e.ID, protocol.ErrPeerOffline, "peer is not attached", 0)
		return
	}

	b, err := json.Marshal(protocol.Envelope{
		V: protocol.Version, Type: e.Type, TS: h.clock.Now().UnixMilli(), Payload: e.Payload,
	})
	if err != nil {
		h.sendErrLocked(c, e.ID, protocol.ErrInternal, "relay failed", 0)
		return
	}
	peer.conn.send(b)
}

func (h *Hub) handleByeLocked(c *Client, e protocol.Envelope) {
	var p protocol.Bye
	if err := protocol.Unmarshal(e, &p); err != nil || p.SessionID == "" {
		h.sendErrLocked(c, e.ID, protocol.ErrBadRequest, "bye requires sessionId", 0)
		return
	}
	s := h.sessions[p.SessionID]
	if s == nil || s.sideFor(c.deviceID) == nil {
		h.sendErrLocked(c, e.ID, protocol.ErrNoSession, "unknown session", 0)
		return
	}
	reason := p.Reason
	if reason == "" {
		reason = protocol.ByeUserEnded
	}
	h.closeSessionLocked(s, reason)
}

func (h *Hub) handleRefresh(c *Client, e protocol.Envelope) {
	h.mu.Lock()
	if !h.acceptAuthedLocked(c, e) {
		h.mu.Unlock()
		return
	}
	deviceID := c.deviceID
	h.mu.Unlock()

	ctx, cancel := registryContext()
	err := h.opt.Registry.BumpEpoch(ctx, deviceID)
	cancel()

	h.mu.Lock()
	defer h.mu.Unlock()
	if errors.Is(err, registry.ErrNotFound) {
		h.sendErrLocked(c, e.ID, protocol.ErrUnknownDevice, "unknown device", 0)
		return
	}
	if err != nil {
		h.sendRegistryErrLocked(c, e.ID, "code refresh", err)
		return
	}
	now := h.clock.Now()
	h.closeSessionsForDeviceLocked(deviceID, protocol.ByeCodeRefreshed)
	h.sendLocked(c, protocol.TypeRefreshCodeOK, e.ID, protocol.RefreshCodeOK{
		DeviceID: deviceID, UpdatedAt: now.UnixMilli()})
	h.log.Info("access code refreshed", "deviceId", deviceID)
}

const SweepInterval = 5 * time.Second
