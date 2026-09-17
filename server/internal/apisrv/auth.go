package apisrv

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"

	"rc-signal/internal/apidb"
	"rc-signal/internal/auth"
	"rc-signal/internal/policy"
	protocol "rcprotocol"
)

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func trimmedLabel(label string) string {
	label = strings.TrimSpace(label)
	if len(label) > protocol.MaxLabelLen {
		label = label[:protocol.MaxLabelLen]
	}
	return label
}

// mintLinkCode is the §1.2 body, shared by the REST endpoint and the /link page.
func (s *Server) mintLinkCode(account *apidb.Account, req protocol.LinkRequest) (protocol.LinkResponse, string, error) {
	existing, err := s.opt.DB.DeviceByPubkey(req.Pubkey)
	switch {
	case err == nil && !existing.Unlinked && existing.AccountID != "" && existing.AccountID != account.AccountID:
		return protocol.LinkResponse{}, protocol.ReasonLinkedElsewhere, nil
	case err != nil && !errors.Is(err, apidb.ErrNotFound):
		return protocol.LinkResponse{}, "", err
	}
	code, err := randomToken(24)
	if err != nil {
		return protocol.LinkResponse{}, "", err
	}
	expiresAt := s.now().Add(protocol.LinkCodeTTLSec * time.Second).UnixMilli()
	record := apidb.LinkCode{
		Code: code, Nonce: req.Nonce, Pubkey: req.Pubkey, Platform: req.Platform,
		Label: trimmedLabel(req.Label), AccountID: account.AccountID, ExpiresAt: expiresAt,
	}
	if err := s.opt.DB.PutLinkCode(record); err != nil {
		return protocol.LinkResponse{}, "", err
	}
	answer := protocol.LinkResponse{Code: code, ExpiresAt: expiresAt}
	if existing != nil && existing.AccountID == account.AccountID {
		answer.DeviceID = existing.DeviceID
	}
	return answer, "", nil
}

func (s *Server) authLink(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitAuthLink, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, func(w http.ResponseWriter) {
		var req protocol.LinkRequest
		if !s.decode(w, r, body, &req) {
			return
		}
		if req.Nonce == "" || req.Platform == "" {
			s.badRequest(w, r, "'nonce' and 'platform' are required")
			return
		}
		if _, err := auth.ParsePubkey(req.Pubkey); err != nil {
			s.badRequest(w, r, "'pubkey' is not a base64 DER SPKI P-256 key")
			return
		}
		answer, conflict, err := s.mintLinkCode(account, req)
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		if conflict != "" {
			s.fail(w, r, http.StatusConflict, protocol.APIErrConflict,
				"that device key is linked to another account", withReason(conflict))
			return
		}
		s.writeJSON(w, r, http.StatusCreated, answer)
	})
}

func (s *Server) authChallenge(w http.ResponseWriter, r *http.Request) {
	if !s.allow(w, r, limitChallengeIP, clientIP(r)) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var req protocol.DeviceChallengeRequest
	if !s.decode(w, r, body, &req) {
		return
	}
	if (req.Code == "") == (req.DeviceID == "") {
		s.badRequest(w, r, "send exactly one of 'code' or 'deviceId'")
		return
	}
	if req.DeviceID != "" {
		if !protocol.ValidDeviceID(req.DeviceID) {
			s.badRequest(w, r, "'deviceId' must be 9 digits")
			return
		}
		if !s.allow(w, r, limitChallengeDevice, req.DeviceID) {
			return
		}
	}
	_, encoded, err := auth.NewNonce()
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	expiresAt := s.now().Add(protocol.APINonceTTLSec * time.Second).UnixMilli()
	if err := s.opt.DB.PutNonce(apidb.Nonce{
		Nonce: encoded, Code: req.Code, DeviceID: req.DeviceID, ExpiresAt: expiresAt,
	}); err != nil {
		s.internalError(w, r, err)
		return
	}
	s.writeJSON(w, r, http.StatusOK, protocol.DeviceChallengeResponse{
		Nonce: encoded, ServerTime: s.nowMS(), ExpiresAt: expiresAt,
	})
}

// verifySignedNonce consumes the §1.3 nonce issued for this code or device and
// checks the device signature over its raw bytes, exactly as signaling does.
func (s *Server) verifySignedNonce(code, deviceID, pubkey, sig string) error {
	nonce, err := s.opt.DB.LatestNonce(code, deviceID, s.nowMS())
	if err != nil {
		return auth.ErrBadSignature
	}
	if _, err := s.opt.DB.ConsumeNonce(nonce.Nonce, s.nowMS()); err != nil {
		return auth.ErrBadSignature
	}
	rawNonce, err := base64.StdEncoding.DecodeString(nonce.Nonce)
	if err != nil {
		return auth.ErrBadSignature
	}
	return auth.VerifyDeviceSig(pubkey, sig, rawNonce)
}

func (s *Server) issueToken(device *apidb.Device) (protocol.DeviceTokenResponse, error) {
	token, err := randomToken(32)
	if err != nil {
		return protocol.DeviceTokenResponse{}, err
	}
	now := s.nowMS()
	expiresAt := now + int64(protocol.DeviceTokenTTLSec)*1000
	if err := s.opt.DB.PutToken(apidb.DeviceToken{
		TokenHash: tokenHash(token), DeviceID: device.DeviceID, AccountID: device.AccountID,
		IssuedAt: now, ExpiresAt: expiresAt,
	}); err != nil {
		return protocol.DeviceTokenResponse{}, err
	}
	return protocol.DeviceTokenResponse{
		DeviceToken: token, ExpiresAt: expiresAt, TTLSec: protocol.DeviceTokenTTLSec,
		DeviceID: device.DeviceID, AccountID: device.AccountID,
	}, nil
}

func (s *Server) authToken(w http.ResponseWriter, r *http.Request) {
	if !s.allow(w, r, limitTokenIP, clientIP(r)) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, "ip:"+clientIP(r), body, func(w http.ResponseWriter) {
		var req protocol.DeviceTokenRequest
		if !s.decode(w, r, body, &req) {
			return
		}
		if req.Code == "" || req.Sig == "" || req.Platform == "" || req.HardwareID == "" {
			s.badRequest(w, r, "'code', 'pubkey', 'sig', 'platform' and 'hardwareId' are required")
			return
		}
		if _, err := auth.ParsePubkey(req.Pubkey); err != nil {
			s.badRequest(w, r, "'pubkey' is not a base64 DER SPKI P-256 key")
			return
		}
		if !s.allow(w, r, limitTokenCode, req.Code) {
			return
		}
		pending, err := s.opt.DB.LinkCodeByCode(req.Code)
		if err != nil || pending.Used || pending.ExpiresAt < s.nowMS() {
			s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "that sign-in code is not usable")
			return
		}
		if pending.Pubkey != req.Pubkey {
			_ = s.opt.DB.UseLinkCode(req.Code)
			s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden,
				"that code was issued for a different device key")
			return
		}
		if err := s.verifySignedNonce(req.Code, "", req.Pubkey, req.Sig); err != nil {
			s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated,
				"the signature over the challenge nonce did not verify")
			return
		}
		registered, err := s.opt.DB.DeviceByPubkey(req.Pubkey)
		if errors.Is(err, apidb.ErrNotFound) {
			s.fail(w, r, http.StatusBadRequest, protocol.APIErrBadRequest,
				"this device key has not registered with signaling yet", withReason(protocol.ReasonUnregistered))
			return
		}
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		if err := s.opt.DB.UseLinkCode(req.Code); err != nil {
			s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated, "that sign-in code is not usable")
			return
		}
		hardwareHash := s.hardwareHash(req.HardwareID)
		req.HardwareID = ""
		device, err := s.linkDevice(registered, pending, req, hardwareHash)
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		grant, err := s.issueToken(device)
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		s.writeJSON(w, r, http.StatusOK, grant)
	})
}

// linkDevice attaches a registered device to the account; the trial starts at its first link.
func (s *Server) linkDevice(device *apidb.Device, pending *apidb.LinkCode, req protocol.DeviceTokenRequest, hardwareHash string) (*apidb.Device, error) {
	label := trimmedLabel(req.Label)
	if label == "" {
		label = pending.Label
	}
	if label == "" {
		label = device.Label
	}
	hardwareSeen, err := s.opt.DB.HardwareSeen(hardwareHash)
	if err != nil {
		return nil, err
	}
	linkedBefore := device.LinkedAt != 0
	trialEndsAt := int64(0)
	if policy.GrantsTrial(linkedBefore, hardwareSeen) {
		trialEndsAt = policy.TrialEndsAt(s.now())
	}
	if err := s.opt.DB.UpdateDeviceLink(device.DeviceID, pending.AccountID, label,
		req.Platform, hardwareHash, trialEndsAt, s.nowMS()); err != nil {
		return nil, err
	}
	return s.opt.DB.DeviceByID(device.DeviceID)
}

func (s *Server) authRefresh(w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, "ip:"+clientIP(r), body, func(w http.ResponseWriter) {
		var req protocol.DeviceRefreshRequest
		if !s.decode(w, r, body, &req) {
			return
		}
		if !protocol.ValidDeviceID(req.DeviceID) || req.Sig == "" {
			s.badRequest(w, r, "'deviceId', 'pubkey' and 'sig' are required")
			return
		}
		if !s.allow(w, r, limitRefreshDevice, req.DeviceID) {
			return
		}
		device, err := s.opt.DB.DeviceByID(req.DeviceID)
		if err != nil || device.Pubkey != req.Pubkey {
			s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "that device is not linked",
				withReason(protocol.EntitlementUnlinked))
			return
		}
		if device.Unlinked || device.AccountID == "" {
			s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden, "that device was unlinked",
				withReason(protocol.EntitlementUnlinked))
			return
		}
		if err := s.verifySignedNonce("", req.DeviceID, req.Pubkey, req.Sig); err != nil {
			s.fail(w, r, http.StatusUnauthorized, protocol.APIErrUnauthenticated,
				"the signature over the challenge nonce did not verify")
			return
		}
		grant, err := s.issueToken(device)
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		s.writeJSON(w, r, http.StatusOK, grant)
	})
}

func (s *Server) authRevoke(w http.ResponseWriter, r *http.Request) {
	device, token, ok := s.deviceAuth(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitRevokeDevice, device.DeviceID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, device.DeviceID, body, func(w http.ResponseWriter) {
		var empty struct{}
		if !s.decode(w, r, body, &empty) {
			return
		}
		if err := s.opt.DB.RevokeToken(token.TokenHash); err != nil {
			s.internalError(w, r, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
