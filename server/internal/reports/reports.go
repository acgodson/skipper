// Package reports delivers session start and stop reports to rc-api. Each session
// has one lane: its events are delivered strictly in order, one at a time, with
// retries, and the total number of waiting events is bounded. A report that is
// finally lost leaves an open row that rc-api's reconciliation sweep closes.
package reports

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	protocol "rcprotocol"
)

type Sink interface {
	SessionStarted(ctx context.Context, r protocol.SessionStartReport) error
	SessionStopped(ctx context.Context, r protocol.SessionStopReport) error
}

// ErrPermanent marks a delivery failure that retrying cannot fix.
var ErrPermanent = errors.New("report permanently rejected")

// ErrDenied marks a start report rc-api refused on entitlement grounds.
var ErrDenied = errors.New("session start denied")

type Options struct {
	Workers     int
	MaxPending  int
	Attempts    int
	Backoff     time.Duration
	MaxBackoff  time.Duration
	CallTimeout time.Duration
	Logger      *slog.Logger
	OnDenied    func(sessionID string)
}

const (
	DefaultWorkers     = 8
	DefaultMaxPending  = 10000
	DefaultAttempts    = 6
	DefaultBackoff     = 250 * time.Millisecond
	DefaultMaxBackoff  = 8 * time.Second
	DefaultCallTimeout = 5 * time.Second
)

func (o *Options) defaults() {
	if o.Workers <= 0 {
		o.Workers = DefaultWorkers
	}
	if o.MaxPending <= 0 {
		o.MaxPending = DefaultMaxPending
	}
	if o.Attempts <= 0 {
		o.Attempts = DefaultAttempts
	}
	if o.Backoff <= 0 {
		o.Backoff = DefaultBackoff
	}
	if o.MaxBackoff <= 0 {
		o.MaxBackoff = DefaultMaxBackoff
	}
	if o.CallTimeout <= 0 {
		o.CallTimeout = DefaultCallTimeout
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
}

type event struct {
	start *protocol.SessionStartReport
	stop  *protocol.SessionStopReport
}

type Queue struct {
	sink Sink
	opt  Options

	mu      sync.Mutex
	cond    *sync.Cond
	lanes   map[string][]event
	busy    map[string]bool
	ready   []string
	pending int
	closed  bool
	stop    chan struct{}
	done    sync.WaitGroup
}

func New(sink Sink, opt Options) *Queue {
	opt.defaults()
	q := &Queue{
		sink: sink, opt: opt,
		lanes: map[string][]event{}, busy: map[string]bool{}, stop: make(chan struct{}),
	}
	q.cond = sync.NewCond(&q.mu)
	for i := 0; i < opt.Workers; i++ {
		q.done.Add(1)
		go q.work()
	}
	return q
}

func (q *Queue) Started(r protocol.SessionStartReport) bool {
	return q.enqueue(r.SessionID, event{start: &r})
}

func (q *Queue) Stopped(r protocol.SessionStopReport) bool {
	return q.enqueue(r.SessionID, event{stop: &r})
}

func (q *Queue) enqueue(sessionID string, ev event) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed || q.pending >= q.opt.MaxPending {
		q.opt.Logger.Error("session report dropped; reconciliation will close the row",
			"sessionId", sessionID, "pending", q.pending)
		return false
	}
	q.lanes[sessionID] = append(q.lanes[sessionID], ev)
	q.pending++
	if !q.busy[sessionID] && len(q.lanes[sessionID]) == 1 {
		q.ready = append(q.ready, sessionID)
		q.cond.Signal()
	}
	return true
}

// Pending is the number of events not yet delivered or given up on.
func (q *Queue) Pending() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.pending
}

func (q *Queue) work() {
	defer q.done.Done()
	q.mu.Lock()
	defer q.mu.Unlock()
	for {
		for len(q.ready) == 0 && !q.closed {
			q.cond.Wait()
		}
		if len(q.ready) == 0 {
			return
		}
		sessionID := q.ready[0]
		q.ready = q.ready[1:]
		q.busy[sessionID] = true
		for len(q.lanes[sessionID]) > 0 {
			ev := q.lanes[sessionID][0]
			q.mu.Unlock()
			q.deliver(sessionID, ev)
			q.mu.Lock()
			q.lanes[sessionID] = q.lanes[sessionID][1:]
			q.pending--
		}
		delete(q.lanes, sessionID)
		delete(q.busy, sessionID)
	}
}

func (q *Queue) deliver(sessionID string, ev event) {
	delay := q.opt.Backoff
	var err error
	for attempt := 1; attempt <= q.opt.Attempts; attempt++ {
		if err = q.send(ev); err == nil {
			return
		}
		if errors.Is(err, ErrPermanent) || errors.Is(err, ErrDenied) || attempt == q.opt.Attempts {
			break
		}
		select {
		case <-time.After(delay):
		case <-q.stop:
			attempt = q.opt.Attempts
		}
		delay = min(2*delay, q.opt.MaxBackoff)
	}
	kind := "stop"
	if ev.start != nil {
		kind = "start"
	}
	q.opt.Logger.Error("session report not delivered", "sessionId", sessionID, "report", kind, "err", err)
	if ev.start != nil && errors.Is(err, ErrDenied) && q.opt.OnDenied != nil {
		q.opt.OnDenied(sessionID)
	}
}

func (q *Queue) send(ev event) error {
	ctx, cancel := context.WithTimeout(context.Background(), q.opt.CallTimeout)
	defer cancel()
	if ev.start != nil {
		return q.sink.SessionStarted(ctx, *ev.start)
	}
	return q.sink.SessionStopped(ctx, *ev.stop)
}

// Close stops accepting events and waits, bounded by ctx, for the queued ones.
// Retry back-off is cut short once ctx ends.
func (q *Queue) Close(ctx context.Context) {
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return
	}
	q.closed = true
	q.cond.Broadcast()
	q.mu.Unlock()
	finished := make(chan struct{})
	go func() {
		q.done.Wait()
		close(finished)
	}()
	select {
	case <-finished:
	case <-ctx.Done():
		close(q.stop)
		<-finished
	}
}
