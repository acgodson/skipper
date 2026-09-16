// Package store is the SQLite device registry.
//
// It stores, per device: the 9-digit device id, the P-256 public key (base64
// SPKI), a human label, and the Argon2id verifier for the access code.
// The plaintext access code is never stored, never accepted here, and never
// logged. Sessions are deliberately NOT persisted: they are in-memory state.
package store

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"time"

	_ "modernc.org/sqlite" // CGO-free driver
	"rcprotocol"
)

// ErrNotFound is returned when no device matches.
var ErrNotFound = errors.New("device not found")

// Device is a registry row.
type Device struct {
	DeviceID  string
	Pubkey    string // base64 DER SPKI
	Label     string
	Code      protocol.CodeVerifier
	CodeEpoch int64 // bumped on every access-code refresh; kills old tokens
	CreatedAt time.Time
	UpdatedAt time.Time
}

// Store wraps the SQLite connection.
type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS devices (
  device_id    TEXT PRIMARY KEY,
  pubkey       TEXT NOT NULL UNIQUE,
  label        TEXT NOT NULL DEFAULT '',
  code_alg     TEXT NOT NULL,
  code_salt    TEXT NOT NULL,
  code_hash    TEXT NOT NULL,
  code_time    INTEGER NOT NULL,
  code_mem_kib INTEGER NOT NULL,
  code_par     INTEGER NOT NULL,
  code_len     INTEGER NOT NULL,
  code_epoch   INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);`

// Open opens (creating if needed) the database at path in WAL mode.
// Use ":memory:" for tests.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	// A single writer keeps things simple and avoids SQLITE_BUSY entirely;
	// this is a two-device system, not a platform.
	db.SetMaxOpenConns(1)
	for _, p := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA foreign_keys=ON",
	} {
		if _, err := db.Exec(p); err != nil {
			db.Close()
			return nil, fmt.Errorf("%s: %w", p, err)
		}
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

const selectCols = `device_id, pubkey, label, code_alg, code_salt, code_hash,
 code_time, code_mem_kib, code_par, code_len, code_epoch, created_at, updated_at`

func scanDevice(row interface{ Scan(...any) error }) (*Device, error) {
	var d Device
	var created, updated int64
	err := row.Scan(&d.DeviceID, &d.Pubkey, &d.Label, &d.Code.Alg, &d.Code.Salt,
		&d.Code.Hash, &d.Code.Time, &d.Code.MemKiB, &d.Code.Par, &d.Code.Len,
		&d.CodeEpoch, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	d.CreatedAt = time.UnixMilli(created)
	d.UpdatedAt = time.UnixMilli(updated)
	return &d, nil
}

// GetDevice looks a device up by id.
func (s *Store) GetDevice(deviceID string) (*Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+selectCols+` FROM devices WHERE device_id = ?`, deviceID))
}

// GetByPubkey looks a device up by its base64 SPKI public key.
func (s *Store) GetByPubkey(pubkey string) (*Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+selectCols+` FROM devices WHERE pubkey = ?`, pubkey))
}

// Register creates a device with a freshly generated 9-digit id. If the public
// key is already registered it returns the existing device and existing=true,
// leaving the stored access-code verifier untouched.
func (s *Store) Register(pubkey, label string, code protocol.CodeVerifier, now time.Time) (dev *Device, existing bool, err error) {
	if d, err := s.GetByPubkey(pubkey); err == nil {
		return d, true, nil
	} else if !errors.Is(err, ErrNotFound) {
		return nil, false, err
	}
	if err := code.Validate(); err != nil {
		return nil, false, err
	}
	ms := now.UnixMilli()
	for attempt := 0; attempt < 20; attempt++ {
		id, err := NewDeviceID()
		if err != nil {
			return nil, false, err
		}
		_, err = s.db.Exec(`INSERT INTO devices
 (device_id, pubkey, label, code_alg, code_salt, code_hash, code_time, code_mem_kib, code_par, code_len, code_epoch, created_at, updated_at)
 VALUES (?,?,?,?,?,?,?,?,?,?,1,?,?)`,
			id, pubkey, label, code.Alg, code.Salt, code.Hash,
			code.Time, code.MemKiB, code.Par, code.Len, ms, ms)
		if err == nil {
			d, err := s.GetDevice(id)
			return d, false, err
		}
		// Unique violation on pubkey means a concurrent registration won.
		if d, e2 := s.GetByPubkey(pubkey); e2 == nil {
			return d, true, nil
		}
		// Otherwise assume a device_id collision and retry.
	}
	return nil, false, errors.New("could not allocate a unique device id")
}

// UpdateCode replaces the access-code verifier and bumps the code epoch,
// which is what makes every previously issued session token invalid.
func (s *Store) UpdateCode(deviceID string, code protocol.CodeVerifier, now time.Time) error {
	if err := code.Validate(); err != nil {
		return err
	}
	res, err := s.db.Exec(`UPDATE devices SET code_alg=?, code_salt=?, code_hash=?,
 code_time=?, code_mem_kib=?, code_par=?, code_len=?, code_epoch=code_epoch+1, updated_at=?
 WHERE device_id=?`,
		code.Alg, code.Salt, code.Hash, code.Time, code.MemKiB, code.Par, code.Len,
		now.UnixMilli(), deviceID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetLabel updates the human label.
func (s *Store) SetLabel(deviceID, label string, now time.Time) error {
	_, err := s.db.Exec(`UPDATE devices SET label=?, updated_at=? WHERE device_id=?`,
		label, now.UnixMilli(), deviceID)
	return err
}

// NewDeviceID returns a cryptographically random 9-digit id with a non-zero
// leading digit, so it is always exactly 9 characters when printed.
func NewDeviceID() (string, error) {
	buf := make([]byte, 9)
	first, err := rand.Int(rand.Reader, big.NewInt(9))
	if err != nil {
		return "", err
	}
	buf[0] = byte('1' + first.Int64())
	for i := 1; i < 9; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(10))
		if err != nil {
			return "", err
		}
		buf[i] = byte('0' + n.Int64())
	}
	return string(buf), nil
}
