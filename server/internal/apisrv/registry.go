package apisrv

import (
	"errors"
	"net/http"

	"rc-signal/internal/apidb"
	"rc-signal/internal/auth"
	protocol "rcprotocol"
)

func (s *Server) internalDevice(w http.ResponseWriter, r *http.Request, status int, d *apidb.Device) {
	cert, err := s.opt.IDCert.Issue(d.DeviceID, d.Pubkey)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	s.writeJSON(w, r, status, protocol.InternalDevice{
		DeviceID: d.DeviceID, Pubkey: d.Pubkey, CodeEpoch: d.CodeEpoch, IDCert: cert})
}

func (s *Server) internalRegister(w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var req protocol.InternalRegisterRequest
	if !s.decode(w, r, body, &req) {
		return
	}
	if _, err := auth.ParsePubkey(req.Pubkey); err != nil {
		s.badRequest(w, r, "'pubkey' is not canonical base64 of a DER SPKI P-256 key")
		return
	}
	if req.PreferredDeviceID != "" && !protocol.ValidDeviceID(req.PreferredDeviceID) {
		s.badRequest(w, r, "'preferredDeviceId' must be 9 digits")
		return
	}
	now := s.nowMS()
	certified := s.opt.IDCert.CertifiedID(req.Pubkey, req.PreferredDeviceID, req.IDCert)
	device, result, err := s.opt.DB.RegisterDevice(apidb.Device{
		Label: protocol.TrimLabel(req.Label), Platform: req.Platform, Pubkey: req.Pubkey,
		CreatedAt: now, LastSeen: now,
	}, certified)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	cert, err := s.opt.IDCert.Issue(device.DeviceID, device.Pubkey)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	if result.Displaced {
		s.opt.Logger.Info("device id restored over another key", "deviceId", device.DeviceID)
	}
	status := http.StatusCreated
	if result.Existing {
		status = http.StatusOK
	}
	s.writeJSON(w, r, status, protocol.InternalRegisterResponse{
		DeviceID: device.DeviceID, Existing: result.Existing, IDCert: cert})
}

func (s *Server) internalDeviceRead(w http.ResponseWriter, r *http.Request) {
	deviceID, ok := s.deviceIDPath(w, r)
	if !ok {
		return
	}
	device, err := s.opt.DB.DeviceByID(deviceID)
	if s.deviceMissing(w, r, err) {
		return
	}
	s.internalDevice(w, r, http.StatusOK, device)
}

func (s *Server) internalEpoch(w http.ResponseWriter, r *http.Request) {
	deviceID, ok := s.deviceIDPath(w, r)
	if !ok {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var empty struct{}
	if !s.decode(w, r, body, &empty) {
		return
	}
	device, err := s.opt.DB.BumpEpoch(deviceID)
	if s.deviceMissing(w, r, err) {
		return
	}
	s.internalDevice(w, r, http.StatusOK, device)
}

func (s *Server) deviceIDPath(w http.ResponseWriter, r *http.Request) (string, bool) {
	deviceID := r.PathValue("deviceId")
	if !protocol.ValidDeviceID(deviceID) {
		s.badRequest(w, r, "'deviceId' must be 9 digits")
		return "", false
	}
	return deviceID, true
}

func (s *Server) deviceMissing(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, apidb.ErrNotFound):
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such device")
	default:
		s.internalError(w, r, err)
	}
	return true
}

// devExpireTrial ends the calling account's trials so the local gating path can be exercised.
// TODO: remove at launch together with /v1/credits/dev-topup.
func (s *Server) devExpireTrial(w http.ResponseWriter, r *http.Request) {
	if s.opt.IdP.Name() != "dev" {
		s.notFound(w, r)
		return
	}
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var empty struct{}
	if !s.decode(w, r, body, &empty) {
		return
	}
	if err := s.opt.DB.ExpireTrials(account.AccountID, s.nowMS()); err != nil {
		s.internalError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
