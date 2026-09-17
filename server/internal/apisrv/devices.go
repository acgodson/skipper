package apisrv

import (
	"errors"
	"net/http"

	"rc-signal/internal/apidb"
	protocol "rcprotocol"
)

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitDeviceList, account.AccountID) {
		return
	}
	if !knownQuery(r, "cursor", "limit") {
		s.badRequest(w, r, "unknown query parameter")
		return
	}
	limit, ok := s.intQuery(w, r, "limit", protocol.DefaultPageLimit, 1, protocol.MaxDevicePageLimit)
	if !ok {
		return
	}
	_, after, valid := s.decodeCursor(r.URL.Query().Get("cursor"))
	if !valid {
		s.badRequest(w, r, "that cursor is not usable")
		return
	}
	devices, err := s.opt.DB.ListDevices(account.AccountID, after, limit+1)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	page := protocol.DeviceList{Devices: []protocol.Device{}}
	for i, d := range devices {
		if i == limit {
			page.NextCursor = encodeCursor(0, devices[i-1].DeviceID, s.nowMS())
			break
		}
		page.Devices = append(page.Devices, d.Public())
	}
	s.writeJSON(w, r, http.StatusOK, page)
}

// getDevice serves a user session or a device token reading its own record.
func (s *Server) getDevice(w http.ResponseWriter, r *http.Request) {
	wanted := r.PathValue("deviceId")
	if token, err := s.opt.DB.TokenByHash(tokenHash(bearer(r))); err == nil {
		device, _, ok := s.deviceAuth(w, r)
		if !ok {
			return
		}
		if !s.allow(w, r, limitDeviceRead, token.DeviceID) {
			return
		}
		if device.DeviceID != wanted {
			s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden,
				"a device token may read only its own record")
			return
		}
		s.writeJSON(w, r, http.StatusOK, device.Public())
		return
	}
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitDeviceRead, account.AccountID) {
		return
	}
	device, err := s.opt.DB.DeviceByID(wanted)
	if err != nil || device.AccountID != account.AccountID || device.Unlinked {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such device on this account")
		return
	}
	s.writeJSON(w, r, http.StatusOK, device.Public())
}

func (s *Server) ownedDevice(w http.ResponseWriter, r *http.Request, account *apidb.Account) (*apidb.Device, bool) {
	device, err := s.opt.DB.DeviceByID(r.PathValue("deviceId"))
	if errors.Is(err, apidb.ErrNotFound) || (err == nil && (device.AccountID != account.AccountID || device.Unlinked)) {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no such device on this account")
		return nil, false
	}
	if err != nil {
		s.internalError(w, r, err)
		return nil, false
	}
	return device, true
}

func (s *Server) renameDevice(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitDeviceWrite, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, replayable, func(w http.ResponseWriter) {
		var req protocol.DeviceRenameRequest
		if !s.decode(w, r, body, &req) {
			return
		}
		label := protocol.TrimLabel(req.Label)
		if label == "" {
			s.badRequest(w, r, "'label' is required")
			return
		}
		device, ok := s.ownedDevice(w, r, account)
		if !ok {
			return
		}
		if err := s.opt.DB.SetLabel(device.DeviceID, label); err != nil {
			s.internalError(w, r, err)
			return
		}
		device.Label = label
		s.writeJSON(w, r, http.StatusOK, device.Public())
	})
}

func (s *Server) unlinkDevice(w http.ResponseWriter, r *http.Request) {
	account, ok := s.userSession(w, r)
	if !ok {
		return
	}
	if !s.allow(w, r, limitDeviceWrite, account.AccountID) {
		return
	}
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	s.idempotent(w, r, account.AccountID, body, replayable, func(w http.ResponseWriter) {
		device, ok := s.ownedDevice(w, r, account)
		if !ok {
			return
		}
		if err := s.opt.DB.UnlinkDevice(device.DeviceID); err != nil {
			s.internalError(w, r, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
