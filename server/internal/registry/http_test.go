package registry

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"rc-signal/internal/clockx"
	"rc-signal/internal/internalapi"
	protocol "rcprotocol"
)

const token = "internal-secret"

type fakeAPI struct {
	mu      sync.Mutex
	devices map[string]protocol.InternalDevice
	lookups int
	status  int
}

func (f *fakeAPI) handler() http.Handler {
	mux := http.NewServeMux()
	guard := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get(protocol.HeaderAuthorization) != protocol.BearerPrefix+token {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			f.mu.Lock()
			status := f.status
			f.mu.Unlock()
			if status != 0 {
				w.WriteHeader(status)
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("POST "+protocol.PathInternalRegister, guard(func(w http.ResponseWriter, r *http.Request) {
		var req protocol.InternalRegisterRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		f.mu.Lock()
		defer f.mu.Unlock()
		for _, d := range f.devices {
			if d.Pubkey == req.Pubkey {
				_ = json.NewEncoder(w).Encode(protocol.InternalRegisterResponse{DeviceID: d.DeviceID, Existing: true})
				return
			}
		}
		d := protocol.InternalDevice{DeviceID: "123456789", Pubkey: req.Pubkey, CodeEpoch: 1}
		f.devices[d.DeviceID] = d
		_ = json.NewEncoder(w).Encode(protocol.InternalRegisterResponse{DeviceID: d.DeviceID})
	}))
	mux.HandleFunc("GET "+protocol.PathInternalDevices+"/{deviceId}", guard(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.lookups++
		d, ok := f.devices[r.PathValue("deviceId")]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(d)
	}))
	mux.HandleFunc("POST "+protocol.PathInternalDevices+"/{deviceId}/epoch", guard(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		d, ok := f.devices[r.PathValue("deviceId")]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		d.CodeEpoch++
		f.devices[d.DeviceID] = d
		_ = json.NewEncoder(w).Encode(d)
	}))
	return mux
}

func (f *fakeAPI) lookupCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.lookups
}

func (f *fakeAPI) failWith(status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
}

func newClient(t *testing.T) (*HTTP, *fakeAPI, *httptest.Server, *clockx.Fake) {
	t.Helper()
	api := &fakeAPI{devices: map[string]protocol.InternalDevice{}}
	srv := httptest.NewServer(api.handler())
	t.Cleanup(srv.Close)
	client, err := internalapi.New(srv.URL, token)
	if err != nil {
		t.Fatal(err)
	}
	clock := clockx.NewFake()
	return NewHTTP(client, clock), api, srv, clock
}

func TestHTTPRegisterIsIdempotentByPubkey(t *testing.T) {
	reg, _, _, _ := newClient(t)
	ctx := context.Background()
	first, existing, err := reg.Register(ctx, "pk-a", "Mac", "")
	if err != nil || existing || first.DeviceID != "123456789" || first.Pubkey != "pk-a" || first.CodeEpoch != 1 {
		t.Fatalf("first register = %+v existing=%v err=%v", first, existing, err)
	}
	again, existing, err := reg.Register(ctx, "pk-a", "Mac", "")
	if err != nil || !existing || again.DeviceID != first.DeviceID {
		t.Fatalf("second register = %+v existing=%v err=%v", again, existing, err)
	}
}

func TestHTTPLookupIsCachedAndBumpEpochInvalidates(t *testing.T) {
	reg, api, _, clock := newClient(t)
	ctx := context.Background()
	dev, _, err := reg.Register(ctx, "pk-b", "", "")
	if err != nil {
		t.Fatal(err)
	}
	before := api.lookupCount()
	for i := 0; i < 3; i++ {
		if got, err := reg.Lookup(ctx, dev.DeviceID); err != nil || got != dev {
			t.Fatalf("cached lookup = %+v, %v", got, err)
		}
	}
	if api.lookupCount() != before {
		t.Fatalf("lookups hit rc-api %d times, want 0 while cached", api.lookupCount()-before)
	}

	if err := reg.BumpEpoch(ctx, dev.DeviceID); err != nil {
		t.Fatal(err)
	}
	got, err := reg.Lookup(ctx, dev.DeviceID)
	if err != nil || got.CodeEpoch != dev.CodeEpoch+1 {
		t.Fatalf("lookup after bump = %+v, %v; want epoch %d", got, err, dev.CodeEpoch+1)
	}
	if api.lookupCount() != before+1 {
		t.Fatalf("bump did not invalidate the cache")
	}

	clock.Advance(CacheTTL)
	if _, err := reg.Lookup(ctx, dev.DeviceID); err != nil {
		t.Fatal(err)
	}
	if api.lookupCount() != before+2 {
		t.Fatalf("an expired cache entry was served")
	}

	if _, err := reg.Lookup(ctx, "999999999"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown device: err = %v, want ErrNotFound", err)
	}
	if err := reg.BumpEpoch(ctx, "999999999"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("bump of an unknown device: err = %v, want ErrNotFound", err)
	}
}

func TestHTTPOutageIsUnavailable(t *testing.T) {
	reg, api, srv, clock := newClient(t)
	ctx := context.Background()
	dev, _, err := reg.Register(ctx, "pk-c", "", "")
	if err != nil {
		t.Fatal(err)
	}

	api.failWith(http.StatusServiceUnavailable)
	if _, _, err := reg.Register(ctx, "pk-d", "", ""); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("register on 503: err = %v, want ErrUnavailable", err)
	}
	if err := reg.BumpEpoch(ctx, dev.DeviceID); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("bump on 503: err = %v, want ErrUnavailable", err)
	}
	if _, err := reg.Lookup(ctx, dev.DeviceID); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("a failed bump must drop the cached epoch; lookup err = %v", err)
	}

	api.failWith(0)
	if _, err := reg.Lookup(ctx, dev.DeviceID); err != nil {
		t.Fatal(err)
	}
	srv.Close()
	if _, err := reg.Lookup(ctx, dev.DeviceID); err != nil {
		t.Fatalf("a cached pubkey should still verify hello during a brief outage: %v", err)
	}
	clock.Advance(CacheTTL)
	if _, err := reg.Lookup(ctx, dev.DeviceID); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("lookup with rc-api gone: err = %v, want ErrUnavailable", err)
	}
	if _, _, err := reg.Register(ctx, "pk-e", "", ""); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("register with rc-api gone: err = %v, want ErrUnavailable", err)
	}
}

func TestHTTPCallsAreBounded(t *testing.T) {
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-block }))
	t.Cleanup(func() { close(block); srv.Close() })
	client, err := internalapi.New(srv.URL, token)
	if err != nil {
		t.Fatal(err)
	}
	reg := NewHTTP(client, clockx.NewFake())
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err := reg.Lookup(ctx, "123456789"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("hung rc-api: err = %v, want ErrUnavailable", err)
	}
	if time.Since(started) > internalapi.CallTimeout {
		t.Fatalf("lookup took %v", time.Since(started))
	}
}
