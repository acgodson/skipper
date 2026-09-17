package apisrv

import (
	"math"
	"net/http"
	"sync"
	"time"

	protocol "rcprotocol"
)

// TODO: this bucket set lives in one process. Horizontal scaling moves it to a
// shared store (ElastiCache or DynamoDB), keyed exactly as it is keyed here.
type rule struct {
	name   string
	limit  float64
	window time.Duration
}

const hour = time.Hour
const day = 24 * time.Hour

var (
	limitHealth          = rule{"health", 60, time.Minute}
	limitAuthLink        = rule{"auth_link", 10, hour}
	limitChallengeIP     = rule{"challenge_ip", 30, hour}
	limitChallengeDevice = rule{"challenge_device", 10, hour}
	limitTokenIP         = rule{"token_ip", 10, hour}
	limitTokenCode       = rule{"token_code", 5, hour}
	limitRefreshDevice   = rule{"refresh_device", 12, day}
	limitRevokeDevice    = rule{"revoke_device", 10, hour}
	limitDeviceList      = rule{"device_list", 60, time.Minute}
	limitDeviceRead      = rule{"device_read", 60, time.Minute}
	limitDeviceWrite     = rule{"device_write", 20, hour}
	limitEntitlement     = rule{"entitlement", 60, hour}
	limitSessionsDevice  = rule{"sessions_device", 60, hour}
	limitSessionsAccount = rule{"sessions_account", 120, hour}
	limitCredits         = rule{"credits", 120, hour}
	limitLedger          = rule{"ledger", 60, hour}
	limitGiftCreate      = rule{"gift_create", 10, day}
	limitGiftList        = rule{"gift_list", 60, hour}
	limitGiftAct         = rule{"gift_act", 20, day}
	limitReleaseLatest   = rule{"release_latest", 60, hour}
)

type bucket struct {
	tokens float64
	seenAt time.Time
}

type limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}

func newLimiter() *limiter { return &limiter{buckets: map[string]*bucket{}} }

func (l *limiter) take(r rule, key string, now time.Time) (bool, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	id := r.name + "|" + key
	b, ok := l.buckets[id]
	if !ok {
		b = &bucket{tokens: r.limit, seenAt: now}
		l.buckets[id] = b
	}
	perSecond := r.limit / r.window.Seconds()
	b.tokens = math.Min(r.limit, b.tokens+now.Sub(b.seenAt).Seconds()*perSecond)
	b.seenAt = now
	if b.tokens < 1 {
		return false, int(math.Ceil((1 - b.tokens) / perSecond))
	}
	b.tokens--
	return true, 0
}

func (s *Server) allow(w http.ResponseWriter, r *http.Request, spec rule, key string) bool {
	ok, retryAfter := s.limiter.take(spec, key, s.now())
	if ok {
		return true
	}
	s.fail(w, r, http.StatusTooManyRequests, protocol.APIErrRateLimited,
		"too many calls to this endpoint", withRetryAfter(retryAfter))
	return false
}
