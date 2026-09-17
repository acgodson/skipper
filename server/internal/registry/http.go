package registry

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"rc-signal/internal/clockx"
	"rc-signal/internal/internalapi"
	protocol "rcprotocol"
)

const (
	CacheTTL        = 5 * time.Minute
	CacheMaxEntries = 10000
)

// HTTP asks rc-api. Any failure to get an answer is ErrUnavailable; it never
// falls back to minting or trusting a local id.
type HTTP struct {
	api   *internalapi.Client
	clock clockx.Clock

	mu    sync.Mutex
	cache map[string]cached
}

type cached struct {
	dev       Device
	fetchedAt time.Time
}

func NewHTTP(api *internalapi.Client, clock clockx.Clock) *HTTP {
	if clock == nil {
		clock = clockx.Real{}
	}
	return &HTTP{api: api, clock: clock, cache: map[string]cached{}}
}

func unavailable(what string, err error) error {
	return fmt.Errorf("%w: %s: %v", ErrUnavailable, what, err)
}

func unexpected(what string, resp internalapi.Response) error {
	return fmt.Errorf("%w: %s: status %d (%s)", ErrUnavailable, what, resp.Status, resp.APIError().Code)
}

func (h *HTTP) Register(ctx context.Context, r Registration) (Registered, error) {
	resp, err := h.api.Do(ctx, http.MethodPost, protocol.PathInternalRegister,
		protocol.InternalRegisterRequest{
			Pubkey: r.Pubkey, Label: r.Label, PreferredDeviceID: r.PreferredDeviceID, IDCert: r.IDCert,
		})
	if err != nil {
		return Registered{}, unavailable("register", err)
	}
	if !resp.OK() {
		return Registered{}, unexpected("register", resp)
	}
	var out protocol.InternalRegisterResponse
	if err := resp.Decode(&out); err != nil || !protocol.ValidDeviceID(out.DeviceID) {
		return Registered{}, unavailable("register", fmt.Errorf("malformed answer: %v", err))
	}
	h.forget(out.DeviceID)
	dev, err := h.Lookup(ctx, out.DeviceID)
	if err != nil {
		return Registered{}, err
	}
	if dev.Pubkey != r.Pubkey {
		return Registered{}, unavailable("register", errors.New("the registered id is bound to another key"))
	}
	return Registered{Device: dev, Existing: out.Existing}, nil
}

func (h *HTTP) Lookup(ctx context.Context, deviceID string) (Device, error) {
	if dev, ok := h.cached(deviceID); ok {
		return dev, nil
	}
	resp, err := h.api.Do(ctx, http.MethodGet, protocol.InternalDevicePath(deviceID), nil)
	if err != nil {
		return Device{}, unavailable("lookup", err)
	}
	if resp.Status == http.StatusNotFound {
		return Device{}, ErrNotFound
	}
	if !resp.OK() {
		return Device{}, unexpected("lookup", resp)
	}
	var out protocol.InternalDevice
	if err := resp.Decode(&out); err != nil || out.DeviceID != deviceID || out.Pubkey == "" {
		return Device{}, unavailable("lookup", fmt.Errorf("malformed answer: %v", err))
	}
	dev := Device{DeviceID: out.DeviceID, Pubkey: out.Pubkey, CodeEpoch: out.CodeEpoch, IDCert: out.IDCert}
	h.remember(dev)
	return dev, nil
}

func (h *HTTP) BumpEpoch(ctx context.Context, deviceID string) error {
	h.forget(deviceID)
	defer h.forget(deviceID)
	resp, err := h.api.Do(ctx, http.MethodPost, protocol.InternalEpochPath(deviceID), struct{}{})
	if err != nil {
		return unavailable("epoch", err)
	}
	if resp.Status == http.StatusNotFound {
		return ErrNotFound
	}
	if !resp.OK() {
		return unexpected("epoch", resp)
	}
	return nil
}

func (h *HTTP) cached(deviceID string) (Device, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry, ok := h.cache[deviceID]
	if !ok || h.clock.Now().Sub(entry.fetchedAt) >= CacheTTL {
		return Device{}, false
	}
	return entry.dev, true
}

func (h *HTTP) remember(dev Device) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.cache) >= CacheMaxEntries {
		h.cache = map[string]cached{}
	}
	h.cache[dev.DeviceID] = cached{dev: dev, fetchedAt: h.clock.Now()}
}

func (h *HTTP) forget(deviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.cache, deviceID)
}
