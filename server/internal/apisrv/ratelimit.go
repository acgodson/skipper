package apisrv

import (
	"net/http"
	"time"

	"rc-signal/internal/ratelimit"
	protocol "rcprotocol"
)

const hour = time.Hour
const day = 24 * time.Hour

type rule = ratelimit.Rule

var (
	limitHealth          = rule{Name: "health", Limit: 60, Window: time.Minute}
	limitAuthLink        = rule{Name: "auth_link", Limit: 10, Window: hour}
	limitChallengeIP     = rule{Name: "challenge_ip", Limit: 30, Window: hour}
	limitTokenIP         = rule{Name: "token_ip", Limit: 10, Window: hour}
	limitTokenCode       = rule{Name: "token_code", Limit: 5, Window: hour}
	limitRefreshIP       = rule{Name: "refresh_ip", Limit: 30, Window: hour}
	limitRefreshDevice   = rule{Name: "refresh_device", Limit: 12, Window: day}
	limitRevokeDevice    = rule{Name: "revoke_device", Limit: 10, Window: hour}
	limitDeviceList      = rule{Name: "device_list", Limit: 60, Window: time.Minute}
	limitDeviceRead      = rule{Name: "device_read", Limit: 60, Window: time.Minute}
	limitDeviceWrite     = rule{Name: "device_write", Limit: 20, Window: hour}
	limitEntitlement     = rule{Name: "entitlement", Limit: 60, Window: hour}
	limitSessionsDevice  = rule{Name: "sessions_device", Limit: 60, Window: hour}
	limitSessionsAccount = rule{Name: "sessions_account", Limit: 120, Window: hour}
	limitCredits         = rule{Name: "credits", Limit: 120, Window: hour}
	limitLedger          = rule{Name: "ledger", Limit: 60, Window: hour}
	limitGiftCreate      = rule{Name: "gift_create", Limit: 10, Window: day}
	limitGiftList        = rule{Name: "gift_list", Limit: 60, Window: hour}
	limitGiftAct         = rule{Name: "gift_act", Limit: 20, Window: day}
	limitReleaseLatest   = rule{Name: "release_latest", Limit: 60, Window: hour}
)

func (s *Server) allow(w http.ResponseWriter, r *http.Request, spec rule, key string) bool {
	ok, retryAfter := s.limiter.Take(s.now(), ratelimit.Charge{Rule: spec, Key: key})
	if ok {
		return true
	}
	s.fail(w, r, http.StatusTooManyRequests, protocol.APIErrRateLimited,
		"too many calls to this endpoint", withRetryAfter(retryAfter))
	return false
}
