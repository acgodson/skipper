package apisrv

import (
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
		balance, err := s.opt.DB.Balance(device.AccountID)
		if err != nil {
			return policy.Decision{}, err
		}
		facts.BalanceCents = balance
		open, err := s.opt.DB.OpenSessionsForAccount(device.AccountID, device.DeviceID)
		if err != nil {
			return policy.Decision{}, err
		}
		facts.ActivePairs = open
	}
	return policy.Decide(facts, s.now()), nil
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
	if !s.internalCaller(w, r) {
		return
	}
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
	if !s.internalCaller(w, r) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var report protocol.SessionStartReport
	if !s.decode(w, r, body, &report) {
		return
	}
	if !protocol.ValidDeviceID(report.HostDeviceID) || !protocol.ValidDeviceID(report.ControllerDeviceID) ||
		report.SessionID == "" {
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
	if !s.internalCaller(w, r) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var report protocol.SessionStopReport
	if !s.decode(w, r, body, &report) {
		return
	}
	if report.SessionID == "" {
		s.badRequest(w, r, "'sessionId' is required")
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
	if err := s.meter(session, endedAt); err != nil {
		s.internalError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) meter(session *apidb.Session, endedAt int64) error {
	if session.HostAccountID == "" {
		return nil
	}
	charge := policy.ChargeCents(millis(endedAt - session.StartedAt))
	if charge <= 0 {
		return nil
	}
	_, err := s.opt.DB.Append(session.HostAccountID, protocol.LedgerSessionCharge, -charge,
		endedAt, session.SessionID, "", "session time")
	return err
}
