// Package deviceid mints 9-digit device ids and decides which id a public key gets.
// A key keeps its id. A specific id is given to a new key only when the caller has
// verified the registry's device-id certificate for that id and key; that restore wins
// over whatever key holds the id now. Without a certificate a new key always gets a
// fresh id, so asking for one reveals nothing about which ids exist. device_id_claims
// keeps every id this database ever assigned, so a fresh id never repeats one.
package deviceid

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"

	protocol "rcprotocol"
)

var ErrTaken = errors.New("device id is taken")

const allocationAttempts = 20

// ClaimsSchema runs after the devices table exists and backfills a claim for every existing row.
const ClaimsSchema = `
CREATE TABLE IF NOT EXISTS device_id_claims (
  device_id TEXT PRIMARY KEY,
  pubkey    TEXT NOT NULL
);
INSERT OR IGNORE INTO device_id_claims (device_id, pubkey)
  SELECT device_id, pubkey FROM devices WHERE pubkey <> '';`

type Ledger interface {
	IDForPubkey(pubkey string) (id string, found bool, err error)
	Claim(id, pubkey string) error
	Restore(id, pubkey string) (displaced bool, err error)
}

// Result.Displaced is true when a restore dropped another key's record of the id.
type Result struct {
	ID        string
	Existing  bool
	Displaced bool
}

// Assign gives pubkey its id. certifiedID is the id a verified certificate binds to
// pubkey, or "" when the caller presented none.
func Assign(l Ledger, pubkey, certifiedID string) (Result, error) {
	if id, found, err := l.IDForPubkey(pubkey); err != nil || found {
		return Result{ID: id, Existing: found}, err
	}
	if certifiedID != "" {
		if !protocol.ValidDeviceID(certifiedID) {
			return Result{}, fmt.Errorf("certified id %q is not 9 digits", certifiedID)
		}
		displaced, err := l.Restore(certifiedID, pubkey)
		if err != nil {
			return Result{}, err
		}
		return Result{ID: certifiedID, Displaced: displaced}, nil
	}
	for i := 0; i < allocationAttempts; i++ {
		fresh, err := New()
		if err != nil {
			return Result{}, err
		}
		err = l.Claim(fresh, pubkey)
		if err == nil {
			return Result{ID: fresh}, nil
		}
		if !errors.Is(err, ErrTaken) {
			return Result{}, err
		}
		if id, found, err := l.IDForPubkey(pubkey); err != nil || found {
			return Result{ID: id, Existing: found}, err
		}
	}
	return Result{}, errors.New("could not allocate a unique device id")
}

func New() (string, error) {
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

// SQL is a Ledger over a SQLite database holding a devices(device_id, pubkey) table and ClaimsSchema.
// Insert writes the new devices row; Evict removes another key's row for an id being restored.
type SQL struct {
	DB     *sql.DB
	Insert func(tx *sql.Tx, id string) error
	Evict  func(tx *sql.Tx, id string) error
}

func (s SQL) IDForPubkey(pubkey string) (string, bool, error) {
	var id string
	err := s.DB.QueryRow(`SELECT device_id FROM devices WHERE pubkey = ?`, pubkey).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return id, err == nil, err
}

func (s SQL) Claim(id, pubkey string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var claimed int
	if err := tx.QueryRow(`SELECT COUNT(1) FROM device_id_claims WHERE device_id = ?`, id).Scan(&claimed); err != nil {
		return err
	}
	var live int
	if err := tx.QueryRow(`SELECT COUNT(1) FROM devices WHERE device_id = ? OR pubkey = ?`, id, pubkey).Scan(&live); err != nil {
		return err
	}
	if claimed > 0 || live > 0 {
		return ErrTaken
	}
	if _, err := tx.Exec(`INSERT INTO device_id_claims (device_id, pubkey) VALUES (?, ?)`, id, pubkey); err != nil {
		return err
	}
	if err := s.Insert(tx, id); err != nil {
		return err
	}
	return tx.Commit()
}

func (s SQL) Restore(id, pubkey string) (bool, error) {
	tx, err := s.DB.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var owner string
	displaced := false
	switch err := tx.QueryRow(`SELECT pubkey FROM devices WHERE device_id = ?`, id).Scan(&owner); {
	case err == nil && owner == pubkey:
		return false, tx.Commit()
	case err == nil:
		if err := s.Evict(tx, id); err != nil {
			return false, err
		}
		displaced = true
	case !errors.Is(err, sql.ErrNoRows):
		return false, err
	}
	if _, err := tx.Exec(`INSERT INTO device_id_claims (device_id, pubkey) VALUES (?, ?)
 ON CONFLICT(device_id) DO UPDATE SET pubkey = excluded.pubkey`, id, pubkey); err != nil {
		return false, err
	}
	if err := s.Insert(tx, id); err != nil {
		return false, err
	}
	return displaced, tx.Commit()
}
