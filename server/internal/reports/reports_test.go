package reports

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"sync"
	"testing"
	"time"

	protocol "rcprotocol"
)

type sink struct {
	mu        sync.Mutex
	log       []string
	failFirst map[string]int
	calls     map[string]int
	permanent error
	denied    bool
	gate      chan struct{}
	inflight  map[string]int
	overlap   bool
}

func newSink() *sink {
	return &sink{failFirst: map[string]int{}, calls: map[string]int{}, inflight: map[string]int{}}
}

func (s *sink) record(ctx context.Context, kind, sessionID string) error {
	s.mu.Lock()
	gate := s.gate
	s.inflight[sessionID]++
	if s.inflight[sessionID] > 1 {
		s.overlap = true
	}
	s.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
		}
	}
	time.Sleep(time.Duration(rand.IntN(200)) * time.Microsecond)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.inflight[sessionID]--
	key := kind + " " + sessionID
	s.calls[key]++
	if s.permanent != nil {
		return s.permanent
	}
	if kind == "start" && s.denied {
		return fmt.Errorf("402: %w", ErrDenied)
	}
	if s.calls[key] <= s.failFirst[key] {
		return errors.New("rc-api is restarting")
	}
	s.log = append(s.log, key)
	return nil
}

func (s *sink) SessionStarted(ctx context.Context, r protocol.SessionStartReport) error {
	return s.record(ctx, "start", r.SessionID)
}

func (s *sink) SessionStopped(ctx context.Context, r protocol.SessionStopReport) error {
	return s.record(ctx, "stop", r.SessionID)
}

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func fast(o Options) Options {
	o.Logger = quiet()
	o.Backoff = time.Millisecond
	o.MaxBackoff = 4 * time.Millisecond
	return o
}

func waitIdle(t *testing.T, q *Queue) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for q.Pending() > 0 {
		if time.Now().After(deadline) {
			t.Fatalf("%d reports still pending", q.Pending())
		}
		time.Sleep(time.Millisecond)
	}
}

func TestEverySessionIsReportedInOrderAndNeverConcurrently(t *testing.T) {
	s := newSink()
	for i := 0; i < 300; i += 7 {
		s.failFirst[fmt.Sprintf("start s%03d", i)] = 2
	}
	q := New(s, fast(Options{}))
	defer q.Close(context.Background())
	for i := 0; i < 300; i++ {
		id := fmt.Sprintf("s%03d", i)
		q.Started(protocol.SessionStartReport{SessionID: id})
		q.Stopped(protocol.SessionStopReport{SessionID: id})
	}
	waitIdle(t, q)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.overlap {
		t.Fatal("two reports for one session were in flight at the same time")
	}
	position := map[string]int{}
	for i, entry := range s.log {
		position[entry] = i
	}
	for i := 0; i < 300; i++ {
		id := fmt.Sprintf("s%03d", i)
		start, okStart := position["start "+id]
		stop, okStop := position["stop "+id]
		if !okStart || !okStop {
			t.Fatalf("%s: start delivered=%v stop delivered=%v", id, okStart, okStop)
		}
		if stop < start {
			t.Fatalf("%s: stop was delivered before start", id)
		}
	}
}

func TestPermanentFailuresAreNotRetried(t *testing.T) {
	s := newSink()
	s.permanent = fmt.Errorf("413: %w", ErrPermanent)
	q := New(s, fast(Options{}))
	defer q.Close(context.Background())
	q.Stopped(protocol.SessionStopReport{SessionID: "a"})
	waitIdle(t, q)
	if got := s.calls["stop a"]; got != 1 {
		t.Fatalf("a permanent failure was tried %d times", got)
	}
}

func TestTransientFailuresGiveUpAfterTheAttemptBudget(t *testing.T) {
	s := newSink()
	s.failFirst["stop a"] = 100
	q := New(s, fast(Options{Attempts: 4}))
	defer q.Close(context.Background())
	q.Stopped(protocol.SessionStopReport{SessionID: "a"})
	waitIdle(t, q)
	if got := s.calls["stop a"]; got != 4 {
		t.Fatalf("attempts = %d, want 4", got)
	}
}

func TestADeniedStartIsReportedBack(t *testing.T) {
	s := newSink()
	s.denied = true
	denied := make(chan string, 1)
	q := New(s, fast(Options{OnDenied: func(id string) { denied <- id }}))
	defer q.Close(context.Background())
	q.Started(protocol.SessionStartReport{SessionID: "a"})
	select {
	case id := <-denied:
		if id != "a" || s.calls["start a"] != 1 {
			t.Fatalf("denied %q after %d calls", id, s.calls["start a"])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a denied start was not reported back")
	}
}

func TestTheQueueIsBounded(t *testing.T) {
	s := newSink()
	s.gate = make(chan struct{})
	q := New(s, fast(Options{Workers: 1, MaxPending: 5}))
	accepted := 0
	for i := 0; i < 50; i++ {
		if q.Started(protocol.SessionStartReport{SessionID: fmt.Sprint(i)}) {
			accepted++
		}
	}
	if accepted != 5 {
		t.Fatalf("accepted %d events with a bound of 5", accepted)
	}
	close(s.gate)
	waitIdle(t, q)
	if !q.Started(protocol.SessionStartReport{SessionID: "late"}) {
		t.Fatal("the queue did not accept events once drained")
	}
	q.Close(context.Background())
	if q.Stopped(protocol.SessionStopReport{SessionID: "after-close"}) {
		t.Fatal("a closed queue accepted an event")
	}
}

func TestCloseFlushesQueuedReports(t *testing.T) {
	s := newSink()
	q := New(s, fast(Options{Workers: 2}))
	for i := 0; i < 20; i++ {
		q.Stopped(protocol.SessionStopReport{SessionID: fmt.Sprint(i)})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	q.Close(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.log) != 20 {
		t.Fatalf("delivered %d of 20 queued reports before Close returned", len(s.log))
	}
}
