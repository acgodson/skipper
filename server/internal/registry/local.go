package registry

import (
	"context"
	"errors"

	"rc-signal/internal/clockx"
	"rc-signal/internal/idcert"
	"rc-signal/internal/store"
)

type Local struct {
	store     *store.Store
	clock     clockx.Clock
	authority *idcert.Authority
}

func NewLocal(st *store.Store, clock clockx.Clock, authority *idcert.Authority) *Local {
	if clock == nil {
		clock = clockx.Real{}
	}
	return &Local{store: st, clock: clock, authority: authority}
}

func device(d *store.Device) Device {
	return Device{DeviceID: d.DeviceID, Pubkey: d.Pubkey, CodeEpoch: d.CodeEpoch}
}

func (l *Local) certified(d *store.Device) (Device, error) {
	dev := device(d)
	cert, err := l.authority.Issue(d.DeviceID, d.Pubkey)
	dev.IDCert = cert
	return dev, err
}

func mapStoreErr(err error) error {
	if errors.Is(err, store.ErrNotFound) {
		return ErrNotFound
	}
	return err
}

func (l *Local) Register(_ context.Context, r Registration) (Registered, error) {
	certified := l.authority.CertifiedID(r.Pubkey, r.PreferredDeviceID, r.IDCert)
	d, result, err := l.store.Register(r.Pubkey, r.Label, certified, l.clock.Now())
	if err != nil {
		return Registered{}, err
	}
	dev, err := l.certified(d)
	return Registered{Device: dev, Existing: result.Existing}, err
}

func (l *Local) Lookup(_ context.Context, deviceID string) (Device, error) {
	d, err := l.store.GetDevice(deviceID)
	if err != nil {
		return Device{}, mapStoreErr(err)
	}
	return device(d), nil
}

func (l *Local) Certify(_ context.Context, deviceID, pubkey string) (Device, error) {
	d, err := l.store.GetDevice(deviceID)
	if err != nil {
		return Device{}, mapStoreErr(err)
	}
	if d.Pubkey != pubkey {
		return Device{}, ErrNotFound
	}
	return l.certified(d)
}

func (l *Local) BumpEpoch(_ context.Context, deviceID string) error {
	return mapStoreErr(l.store.BumpEpoch(deviceID, l.clock.Now()))
}
