// Package ratelimit is the token-bucket limiter both server commands use.
// A bucket that has refilled completely carries no information and is evicted.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

// TODO: this bucket set lives in one process. Horizontal scaling moves it to a
// shared store (ElastiCache or DynamoDB), keyed exactly as it is keyed here.

// Rule allows Limit events per Window with a burst of Limit.
type Rule struct {
	Name   string
	Limit  float64
	Window time.Duration
}

func (r Rule) perSecond() float64 { return r.Limit / r.Window.Seconds() }

// Charge names one bucket: a rule applied to a key.
type Charge struct {
	Rule Rule
	Key  string
}

type bucket struct {
	tokens float64
	seenAt time.Time
	window time.Duration
}

type Limiter struct {
	mu        sync.Mutex
	buckets   map[string]*bucket
	lastSweep time.Time
}

// SweepEvery bounds how often Take scans for idle buckets.
const SweepEvery = time.Minute

func New() *Limiter { return &Limiter{buckets: map[string]*bucket{}} }

// Take spends one token from every bucket only if every bucket has one;
// otherwise it spends nothing and returns the longest wait in whole seconds.
func (l *Limiter) Take(now time.Time, charges ...Charge) (bool, int) {
	return l.check(now, true, charges)
}

// Room answers what Take would, without spending anything.
func (l *Limiter) Room(now time.Time, charges ...Charge) (bool, int) {
	return l.check(now, false, charges)
}

func (l *Limiter) check(now time.Time, spend bool, charges []Charge) (bool, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.evictIdleLocked(now)
	buckets := make([]*bucket, len(charges))
	wait := 0
	for i, c := range charges {
		b := l.refillLocked(c, now)
		buckets[i] = b
		if b.tokens < 1 {
			sec := int(math.Ceil((1 - b.tokens) / c.Rule.perSecond()))
			wait = max(wait, max(sec, 1))
		}
	}
	if wait > 0 || !spend {
		return wait == 0, wait
	}
	for _, b := range buckets {
		b.tokens--
	}
	return true, 0
}

func (l *Limiter) refillLocked(c Charge, now time.Time) *bucket {
	id := c.Rule.Name + "|" + c.Key
	b, ok := l.buckets[id]
	if !ok {
		b = &bucket{tokens: c.Rule.Limit, seenAt: now, window: c.Rule.Window}
		l.buckets[id] = b
	}
	elapsed := now.Sub(b.seenAt).Seconds()
	if elapsed > 0 {
		b.tokens = math.Min(c.Rule.Limit, b.tokens+elapsed*c.Rule.perSecond())
		b.seenAt = now
	}
	return b
}

func (l *Limiter) evictIdleLocked(now time.Time) {
	if now.Sub(l.lastSweep) < SweepEvery {
		return
	}
	l.lastSweep = now
	for id, b := range l.buckets {
		if now.Sub(b.seenAt) >= b.window {
			delete(l.buckets, id)
		}
	}
}

// Len is the number of buckets currently held.
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
