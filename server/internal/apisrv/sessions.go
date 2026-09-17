package apisrv

import (
	"net/http"

	"rc-signal/internal/apidb"
	protocol "rcprotocol"
)

func (s *Server) listSessions(w http.ResponseWriter, r *http.Request) {
	if !knownQuery(r, "since", "until", "cursor", "limit", "deviceId") {
		s.badRequest(w, r, "unknown query parameter")
		return
	}
	var deviceIDs []string
	var callerDevice string
	if _, err := s.opt.DB.TokenByHash(tokenHash(bearer(r))); err == nil {
		device, _, ok := s.deviceAuth(w, r)
		if !ok {
			return
		}
		if r.URL.Query().Get("deviceId") != "" {
			s.fail(w, r, http.StatusForbidden, protocol.APIErrForbidden,
				"'deviceId' is a user-session filter")
			return
		}
		if !s.allow(w, r, limitSessionsDevice, device.DeviceID) {
			return
		}
		deviceIDs = []string{device.DeviceID}
		callerDevice = device.DeviceID
	} else {
		account, ok := s.userSession(w, r)
		if !ok {
			return
		}
		if !s.allow(w, r, limitSessionsAccount, account.AccountID) {
			return
		}
		devices, err := s.opt.DB.ListDevices(account.AccountID, "", protocol.MaxDevicePageLimit)
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		wanted := r.URL.Query().Get("deviceId")
		for _, d := range devices {
			if wanted == "" || d.DeviceID == wanted {
				deviceIDs = append(deviceIDs, d.DeviceID)
			}
		}
		callerDevice = wanted
	}

	since, ok := s.msQuery(w, r, "since", true)
	if !ok {
		return
	}
	until, ok := s.msQuery(w, r, "until", false)
	if !ok {
		return
	}
	limit, ok := s.intQuery(w, r, "limit", protocol.DefaultHistoryPageLimit, 1, protocol.MaxHistoryPageLimit)
	if !ok {
		return
	}
	after, afterID, valid := s.decodeCursor(r.URL.Query().Get("cursor"))
	if !valid {
		s.badRequest(w, r, "that cursor is not usable")
		return
	}
	sessions, err := s.opt.DB.ListSessions(apidb.SessionQuery{
		DeviceIDs: deviceIDs, Since: since, Until: until, After: after, AfterID: afterID, Limit: limit + 1,
	})
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	page := protocol.SessionList{Sessions: []protocol.SessionRecord{}}
	for i, record := range sessions {
		if i == limit {
			previous := sessions[i-1]
			page.NextCursor = encodeCursor(previous.StartedAt, previous.SessionID, s.nowMS())
			break
		}
		page.Sessions = append(page.Sessions, publicSession(record, callerDevice))
	}
	s.writeJSON(w, r, http.StatusOK, page)
}

func publicSession(record apidb.Session, callerDevice string) protocol.SessionRecord {
	role := protocol.RoleController
	peer := record.HostDeviceID
	if record.HostDeviceID == callerDevice || callerDevice == "" {
		role = protocol.RoleHost
		peer = record.ControllerDeviceID
	}
	out := protocol.SessionRecord{
		SessionID: record.SessionID, PeerDeviceID: peer, Role: role,
		StartedAt: record.StartedAt, EndedAt: record.EndedAt, RelayUsed: record.RelayUsed,
	}
	if record.RelayUsed {
		out.BytesRelayed = record.BytesRelayed
	}
	return out
}
