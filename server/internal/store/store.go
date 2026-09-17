// Package store is rc-signal's stand-alone SQLite device registry: device id, P-256 public key,
// label and code epoch, the controller/host pairs that have had a metered session, and (in a
// separate database file) the durable device-id claims. Sessions are in-memory only.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"rc-signal/internal/deviceid"
	"rc-signal/internal/sqlitex"
)

var ErrNotFound = errors.New("device not found")

type Device struct {
	DeviceID  string
	Pubkey    string
	Label     string
	CodeEpoch int64
	CreatedAt time.Time
	UpdatedAt time.Time
}

type Store struct {
	db     *sql.DB
	claims *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS devices (
  device_id    TEXT PRIMARY KEY,
  pubkey       TEXT NOT NULL UNIQUE,
  label        TEXT NOT NULL DEFAULT '',
  code_epoch   INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS known_pairs (
  host_device_id       TEXT NOT NULL,
  controller_device_id TEXT NOT NULL,
  first_metered_at     INTEGER NOT NULL,
  PRIMARY KEY (host_device_id, controller_device_id)
);`

// Open opens the registry at path and the device-id claims at claimsPath, which the operator
// keeps and backs up separately and never resets together with path.
func Open(path, claimsPath string) (*Store, error) {
	db, err := sqlitex.Open(path, schema)
	if err != nil {
		return nil, err
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	claims, err := deviceid.OpenClaims(claimsPath, db)
	if err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db, claims: claims}, nil
}

func migrate(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(devices)`)
	if err != nil {
		return err
	}
	hasVerifier := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var dflt any
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "code_hash" {
			hasVerifier = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if !hasVerifier {
		return nil
	}
	stmts := []string{
		`CREATE TABLE devices_v2 (
  device_id    TEXT PRIMARY KEY,
  pubkey       TEXT NOT NULL UNIQUE,
  label        TEXT NOT NULL DEFAULT '',
  code_epoch   INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
)`,
		`INSERT INTO devices_v2 (device_id, pubkey, label, code_epoch, created_at, updated_at)
 SELECT device_id, pubkey, label, code_epoch, created_at, updated_at FROM devices`,
		`DROP TABLE devices`,
		`ALTER TABLE devices_v2 RENAME TO devices`,
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			tx.Rollback()
			return fmt.Errorf("v1->v2 migration (%s): %w", stmt, err)
		}
	}
	return tx.Commit()
}

func (s *Store) Close() error { return errors.Join(s.db.Close(), s.claims.Close()) }

const selectCols = `device_id, pubkey, label, code_epoch, created_at, updated_at`

func scanDevice(row interface{ Scan(...any) error }) (*Device, error) {
	var d Device
	var created, updated int64
	err := row.Scan(&d.DeviceID, &d.Pubkey, &d.Label, &d.CodeEpoch, &created, &updated)
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

func (s *Store) GetDevice(deviceID string) (*Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+selectCols+` FROM devices WHERE device_id = ?`, deviceID))
}

func (s *Store) GetByPubkey(pubkey string) (*Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+selectCols+` FROM devices WHERE pubkey = ?`, pubkey))
}

// Register assigns pubkey its id; certifiedID is an id a verified device-id certificate binds to pubkey, or "".
func (s *Store) Register(pubkey, label, certifiedID string, now time.Time) (*Device, deviceid.Result, error) {
	ms := now.UnixMilli()
	ledger := deviceid.SQL{
		DB: s.db, Claims: s.claims,
		Insert: func(tx *sql.Tx, id string) error {
			_, err := tx.Exec(`INSERT INTO devices
 (device_id, pubkey, label, code_epoch, created_at, updated_at)
 VALUES (?,?,?,1,?,?)`, id, pubkey, label, ms, ms)
			return err
		},
		Evict: func(tx *sql.Tx, id string) error {
			_, err := tx.Exec(`DELETE FROM devices WHERE device_id=?`, id)
			return err
		},
	}
	result, err := deviceid.Assign(ledger, pubkey, certifiedID)
	if err != nil {
		return nil, result, err
	}
	d, err := s.GetDevice(result.ID)
	return d, result, err
}

func (s *Store) BumpEpoch(deviceID string, now time.Time) error {
	res, err := s.db.Exec(
		`UPDATE devices SET code_epoch=code_epoch+1, updated_at=? WHERE device_id=?`,
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

func (s *Store) SetLabel(deviceID, label string, now time.Time) error {
	_, err := s.db.Exec(`UPDATE devices SET label=?, updated_at=? WHERE device_id=?`,
		label, now.UnixMilli(), deviceID)
	return err
}

func (s *Store) RecordPair(hostDeviceID, controllerDeviceID string, at time.Time) error {
	_, err := s.db.Exec(`INSERT INTO known_pairs (host_device_id, controller_device_id, first_metered_at)
 VALUES (?,?,?) ON CONFLICT DO NOTHING`, hostDeviceID, controllerDeviceID, at.UnixMilli())
	return err
}

func (s *Store) KnownPair(hostDeviceID, controllerDeviceID string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(1) FROM known_pairs WHERE host_device_id=? AND controller_device_id=?`,
		hostDeviceID, controllerDeviceID).Scan(&n)
	return n > 0, err
}
