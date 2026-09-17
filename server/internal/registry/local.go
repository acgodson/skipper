package registry

import (
	"context"
	"errors"

	"rc-signal/internal/clockx"
	"rc-signal/internal/store"
)

type Local struct {
	store *store.Store
	clock clockx.Clock
}

func NewLocal(st *store.Store, clock clockx.Clock) *Local {
	if clock == nil {
		clock = clockx.Real{}
	}
	return &Local{store: st, clock: clock}
}

func fromStore(d *store.Device) Device {
	return Device{DeviceID: d.DeviceID, Pubkey: d.Pubkey, CodeEpoch: d.CodeEpoch}
}

func mapStoreErr(err error) error {
	if errors.Is(err, store.ErrNotFound) {
		return ErrNotFound
	}
	return err
}

func (l *Local) Register(_ context.Context, pubkey, label string) (Device, bool, error) {
	d, existing, err := l.store.Register(pubkey, label, l.clock.Now())
	if err != nil {
		return Device{}, false, err
	}
	return fromStore(d), existing, nil
}

func (l *Local) Lookup(_ context.Context, deviceID string) (Device, error) {
	d, err := l.store.GetDevice(deviceID)
	if err != nil {
		return Device{}, mapStoreErr(err)
	}
	return fromStore(d), nil
}

func (l *Local) BumpEpoch(_ context.Context, deviceID string) error {
	return mapStoreErr(l.store.BumpEpoch(deviceID, l.clock.Now()))
}
