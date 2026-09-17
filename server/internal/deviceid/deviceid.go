// Package deviceid mints 9-digit device ids and decides which id a public key gets.
// A key keeps its id forever. A preferred id is honoured only for a new key, and only when
// no other key holds it now or ever held it: every id ever assigned stays in
// device_id_claims, so it is never handed to a different key.
package deviceid

import (
	"crypto/rand"
	"database/sql"
	"errors"
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
}

func Assign(l Ledger, pubkey, preferred string) (id string, existing bool, err error) {
	if id, found, err := l.IDForPubkey(pubkey); err != nil || found {
		return id, found, err
	}
	if protocol.ValidDeviceID(preferred) {
		if id, existing, done, err := attempt(l, preferred, pubkey); done {
			return id, existing, err
		}
	}
	for i := 0; i < allocationAttempts; i++ {
		fresh, err := New()
		if err != nil {
			return "", false, err
		}
		if id, existing, done, err := attempt(l, fresh, pubkey); done {
			return id, existing, err
		}
	}
	return "", false, errors.New("could not allocate a unique device id")
}

func attempt(l Ledger, id, pubkey string) (assigned string, existing, done bool, err error) {
	err = l.Claim(id, pubkey)
	if err == nil {
		return id, false, true, nil
	}
	if !errors.Is(err, ErrTaken) {
		return "", false, true, err
	}
	if known, found, err := l.IDForPubkey(pubkey); err != nil || found {
		return known, found, true, err
	}
	return "", false, false, nil
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
type SQL struct {
	DB     *sql.DB
	Insert func(tx *sql.Tx, id string) error
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
	var owner string
	switch err := tx.QueryRow(`SELECT pubkey FROM device_id_claims WHERE device_id = ?`, id).Scan(&owner); {
	case err == nil && owner != pubkey:
		return ErrTaken
	case err != nil && !errors.Is(err, sql.ErrNoRows):
		return err
	}
	var live int
	if err := tx.QueryRow(`SELECT COUNT(1) FROM devices WHERE device_id = ? OR pubkey = ?`, id, pubkey).Scan(&live); err != nil {
		return err
	}
	if live > 0 {
		return ErrTaken
	}
	if _, err := tx.Exec(`INSERT OR IGNORE INTO device_id_claims (device_id, pubkey) VALUES (?, ?)`, id, pubkey); err != nil {
		return err
	}
	if err := s.Insert(tx, id); err != nil {
		return err
	}
	return tx.Commit()
}
