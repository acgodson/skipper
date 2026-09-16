// Package store is the SQLite device registry.
// It stores the device id, P-256 public key, label and code epoch; sessions are in-memory only.
package store

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"time"

	_ "modernc.org/sqlite"
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
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS devices (
  device_id    TEXT PRIMARY KEY,
  pubkey       TEXT NOT NULL UNIQUE,
  label        TEXT NOT NULL DEFAULT '',
  code_epoch   INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);`

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}

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
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
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

func (s *Store) Close() error { return s.db.Close() }

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

func (s *Store) Register(pubkey, label string, now time.Time) (dev *Device, existing bool, err error) {
	if d, err := s.GetByPubkey(pubkey); err == nil {
		return d, true, nil
	} else if !errors.Is(err, ErrNotFound) {
		return nil, false, err
	}
	ms := now.UnixMilli()
	for attempt := 0; attempt < 20; attempt++ {
		id, err := NewDeviceID()
		if err != nil {
			return nil, false, err
		}
		_, err = s.db.Exec(`INSERT INTO devices
 (device_id, pubkey, label, code_epoch, created_at, updated_at)
 VALUES (?,?,?,1,?,?)`, id, pubkey, label, ms, ms)
		if err == nil {
			d, err := s.GetDevice(id)
			return d, false, err
		}

		if d, e2 := s.GetByPubkey(pubkey); e2 == nil {
			return d, true, nil
		}

	}
	return nil, false, errors.New("could not allocate a unique device id")
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
