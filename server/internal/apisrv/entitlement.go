package apisrv

import (
	"context"
	"errors"
	"net/http"

	"rc-signal/internal/apidb"
	"rc-signal/internal/policy"
	protocol "rcprotocol"
)

// decide answers for a device; nil is a device the registry has never seen.
func (s *Server) decide(device *apidb.Device) (policy.Decision, error) {
	if device == nil {
		return policy.Decide(policy.Facts{}, s.now()), nil
	}
	facts := policy.Facts{
		Known:       true,
		Unlinked:    device.Unlinked || device.AccountID == "",
		TrialEndsAt: device.TrialEndsAt,
	}
	if device.AccountID != "" {
		account, err := s.opt.DB.AccountByID(device.AccountID)
		if err != nil && !errors.Is(err, apidb.ErrNotFound) {
			return policy.Decision{}, err
		}
		if err == nil {
			facts.HasAccount = true
			facts.Suspended = account.Suspended
		}
		// The grant is one per account, so its window is the account's, not this
		// device's: a second device on the account spends the same starting credits.
		window, err := s.opt.DB.TrialWindowForAccount(device.AccountID)
		if err != nil {
			return policy.Decision{}, err
		}
		facts.TrialEndsAt = window
		if facts.HasAccount {
			if err := s.settleExpiredGrant(device.AccountID, window); err != nil {
				return policy.Decision{}, err
			}
		}
		balance, err := s.opt.DB.Balance(device.AccountID)
		if err != nil {
			return policy.Decision{}, err
		}
		facts.BalanceCents = balance
		grant, _, err := s.opt.DB.UnconsumedGrant(device.AccountID)
		if err != nil {
			return policy.Decision{}, err
		}
		facts.UnconsumedGrant = grant
		open, err := s.opt.DB.OpenSessionsForAccount(device.AccountID, device.DeviceID)
		if err != nil {
			return policy.Decision{}, err
		}
		facts.ActivePairs = open
	}
	return policy.Decide(facts, s.now()), nil
}

// settleExpiredGrant writes the one trial_expiry entry that closes a grant window,
// the first time anybody asks after it has passed. The window is a property of the
// ledger and the device rows, so there is nothing to schedule: the answer is settled
// before it is given, and an unasked account costs nothing.
//
// It claws back only grant no session consumed, so a top-up is never taken back.
// windowEndsAt is the account's latest window, so one device's expiry never closes
// a window another device on the account is still inside.
func (s *Server) settleExpiredGrant(accountID string, windowEndsAt int64) error {
	now := s.nowMS()
	if windowEndsAt == 0 || windowEndsAt > now {
		return nil
	}
	grant, open, err := s.opt.DB.UnconsumedGrant(accountID)
	if err != nil || !open {
		return err
	}
	balance, err := s.opt.DB.Balance(accountID)
	if err != nil {
		return err
	}
	clawback := policy.ExpiredGrantClawback(grant, balance)
	_, err = s.opt.DB.Append(accountID, protocol.LedgerTrialExpiry, -clawback, now,
		"", "", "starting credits expired")
	return err
}

func (s *Server) entitlement(w http.ResponseWriter, r *http.Request) {
	device, _, ok := s.deviceAuth(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitEntitlement, device.DeviceID) {
		return
	}
	decision, err := s.decide(device)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	s.writeJSON(w, r, http.StatusOK, decision.Entitlement)
}

// signalingDevice resolves a host the signaling server names; an unknown id is nil, never a new record.
func (s *Server) signalingDevice(deviceID string) (*apidb.Device, error) {
	device, err := s.opt.DB.DeviceByID(deviceID)
	if errors.Is(err, apidb.ErrNotFound) {
		return nil, nil
	}
	return device, err
}

func (s *Server) internalEntitlement(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("deviceId")
	if !protocol.ValidDeviceID(deviceID) {
		s.badRequest(w, r, "'deviceId' must be 9 digits")
		return
	}
	device, err := s.signalingDevice(deviceID)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	decision, err := s.decide(device)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	if decision.Reason != "" {
		s.fail(w, r, http.StatusPaymentRequired, protocol.APIErrEntitlement,
			"this host may not open a session right now", withReason(decision.Reason))
		return
	}
	s.writeJSON(w, r, http.StatusOK, decision.Entitlement)
}

func (s *Server) internalSessionStart(w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var report protocol.SessionStartReport
	if !s.decode(w, r, body, &report) {
		return
	}
	if !protocol.ValidDeviceID(report.HostDeviceID) || !protocol.ValidDeviceID(report.ControllerDeviceID) ||
		!protocol.ValidSessionID(report.SessionID) {
		s.badRequest(w, r, "'sessionId', 'hostDeviceId' and 'controllerDeviceId' are required")
		return
	}
	host, err := s.signalingDevice(report.HostDeviceID)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	decision, err := s.decide(host)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	if decision.Reason == protocol.EntitlementConcurrency {
		s.fail(w, r, http.StatusPaymentRequired, protocol.APIErrEntitlement,
			"this account already holds an active pair", withReason(decision.Reason))
		return
	}
	startedAt := report.StartedAt
	if startedAt == 0 {
		startedAt = s.nowMS()
	}
	if err := s.opt.DB.StartSession(apidb.Session{
		SessionID: report.SessionID, HostDeviceID: report.HostDeviceID,
		ControllerDeviceID: report.ControllerDeviceID, HostAccountID: hostAccount(host),
		StartedAt: startedAt,
	}); err != nil {
		s.internalError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func hostAccount(host *apidb.Device) string {
	if host == nil {
		return ""
	}
	return host.AccountID
}

func (s *Server) internalSessionStop(w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var report protocol.SessionStopReport
	if !s.decode(w, r, body, &report) {
		return
	}
	if !protocol.ValidSessionID(report.SessionID) || !protocol.ValidByeReason(report.Reason) {
		s.badRequest(w, r, "'sessionId' and a defined 'reason' are required")
		return
	}
	session, err := s.opt.DB.SessionByID(report.SessionID)
	if errors.Is(err, apidb.ErrNotFound) {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such session")
		return
	}
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	endedAt := report.EndedAt
	if endedAt == 0 {
		endedAt = s.nowMS()
	}
	if err := s.opt.DB.StopSession(report.SessionID, endedAt, report.RelayUsed,
		report.BytesRelayed, report.Reason); err != nil {
		if errors.Is(err, apidb.ErrNotFound) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		s.internalError(w, r, err)
		return
	}
	if err := s.meter(r.Context(), session, endedAt); err != nil {
		s.internalError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// LiveSessions asks signaling which metered sessions it still holds.
type LiveSessions func(ctx context.Context) (protocol.InternalLiveSessions, error)

// Reconcile closes every open session row signaling no longer knows, billing it
// up to the last time signaling was seen holding it. Rows are read before
// signaling is asked, so a session that starts in between is never closed.
// TODO: with several rc-signal instances in Phase 5, ask every instance and close only what none holds.
func (s *Server) Reconcile(ctx context.Context, live LiveSessions) (int, error) {
	pending := s.retryPendingCloses(ctx)
	closed, err := s.reconcileOpenSessions(ctx, live)
	return closed, errors.Join(err, pending)
}

// retryPendingCloses re-issues every unlink whose session close signaling did
// not confirm, and keeps the record until it does.
func (s *Server) retryPendingCloses(ctx context.Context) error {
	if s.opt.CloseSessions == nil {
		return nil
	}
	pending, err := s.opt.DB.PendingCloses()
	if err != nil || len(pending) == 0 {
		return err
	}
	var failures error
	for _, p := range pending {
		if err := s.opt.CloseSessions(ctx, p.DeviceID, p.Reason); err != nil {
			failures = errors.Join(failures, err)
			continue
		}
		if err := s.opt.DB.ClearPendingClose(p.DeviceID); err != nil {
			return errors.Join(failures, err)
		}
		s.opt.Logger.Info("pending session close confirmed", "deviceId", p.DeviceID)
	}
	return failures
}

func (s *Server) reconcileOpenSessions(ctx context.Context, live LiveSessions) (int, error) {
	open, err := s.opt.DB.OpenSessions()
	if err != nil || len(open) == 0 {
		return 0, err
	}
	snapshot, err := live(ctx)
	if err != nil {
		return 0, err
	}
	seenAt := snapshot.ServerTime
	if seenAt == 0 {
		seenAt = s.nowMS()
	}
	held := make(map[string]bool, len(snapshot.SessionIDs))
	for _, id := range snapshot.SessionIDs {
		held[id] = true
	}
	closed := 0
	for i := range open {
		row := &open[i]
		if held[row.SessionID] {
			if err := s.opt.DB.MarkAlive(row.SessionID, seenAt); err != nil {
				return closed, err
			}
			if err := s.cutOffSpentSession(ctx, row); err != nil {
				return closed, err
			}
			continue
		}
		endedAt := max(row.LastAliveAt, row.StartedAt)
		err := s.opt.DB.StopSession(row.SessionID, endedAt, false, nil, protocol.SessionReasonReconciled)
		if errors.Is(err, apidb.ErrNotFound) {
			continue
		}
		if err != nil {
			return closed, err
		}
		if err := s.meter(ctx, row, endedAt); err != nil {
			return closed, err
		}
		closed++
		s.opt.Logger.Info("session reconciled", "sessionId", row.SessionID, "endedAt", endedAt)
	}
	return closed, nil
}

// cutOffSpentSession ends a live metered session whose account has no balance left.
// A session is settled when it stops, so between settlements it can outrun the
// balance; this is the tick that bounds the overrun to one sweep. It charges nothing
// — the stop report still settles the whole session — it only stops the running.
func (s *Server) cutOffSpentSession(ctx context.Context, session *apidb.Session) error {
	if session.HostAccountID == "" {
		return nil
	}
	balance, err := s.opt.DB.Balance(session.HostAccountID)
	if err != nil || balance >= policy.MinBalanceCents {
		return err
	}
	s.opt.Logger.Info("a live session has no balance behind it; closing it",
		"sessionId", session.SessionID, "deviceId", session.HostDeviceID)
	return s.closeDeviceSessions(ctx, session.HostDeviceID)
}

// meter settles one ended session. Metering is deliberately blind to status: a trial
// is credit now, so a trial session debits the grant like any other.
//
// A charge the balance cannot cover is clamped by the ledger, never refused — the
// session has already happened — and a clamped charge means the account has run out,
// so the host stops hosting rather than running free on a balance of zero.
func (s *Server) meter(ctx context.Context, session *apidb.Session, endedAt int64) error {
	if session.HostAccountID == "" {
		return nil
	}
	duration := millis(endedAt - session.StartedAt)
	settled, err := s.opt.DB.SettleCharge(session.HostAccountID, session.SessionID, endedAt,
		func(carry int64) (int64, int64) { return policy.Charge(duration, carry) })
	if errors.Is(err, apidb.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if !settled.Clamped {
		return nil
	}
	s.opt.Logger.Info("the balance ran out mid-session; closing the host's sessions",
		"sessionId", session.SessionID, "deviceId", session.HostDeviceID)
	return s.closeDeviceSessions(ctx, session.HostDeviceID)
}
