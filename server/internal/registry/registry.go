// Package registry is the one device registry rc-signal consults: which
// deviceId belongs to which public key, and the code epoch of each device.
// Local mode keeps it in rc-signal's SQLite store; http mode asks rc-api, which owns it.
package registry

import (
	"context"
	"errors"

	"rc-signal/internal/internalapi"
)

// CallBudget bounds one registry operation end to end; Register may take two internal calls.
const CallBudget = 2 * internalapi.CallTimeout

var (
	ErrNotFound    = errors.New("device not found")
	ErrUnavailable = errors.New("device registry unavailable")
)

type Device struct {
	DeviceID  string
	Pubkey    string
	CodeEpoch int64
}

type Registry interface {
	Register(ctx context.Context, pubkey, label, preferredDeviceID string) (dev Device, existing bool, err error)
	Lookup(ctx context.Context, deviceID string) (Device, error)
	BumpEpoch(ctx context.Context, deviceID string) error
}
