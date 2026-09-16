// Package clockx provides the tiny clock abstraction the server uses so that
// every time-dependent behaviour (presence timeouts, token TTLs, rate-limit
// lockouts) can be tested deterministically without sleeping.
package clockx

import (
	"sync"
	"time"
)

// Clock is the seam. Production uses Real; tests use Fake.
type Clock interface {
	Now() time.Time
}

// Real is the system clock.
type Real struct{}

func (Real) Now() time.Time { return time.Now() }

// Fake is a manually advanced clock, safe for concurrent use.
type Fake struct {
	mu sync.Mutex
	t  time.Time
}

// NewFake returns a Fake clock started at a fixed, arbitrary instant.
func NewFake() *Fake {
	return &Fake{t: time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)}
}

func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

// Advance moves the fake clock forward.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.t = f.t.Add(d)
}
