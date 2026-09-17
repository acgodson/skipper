// Package deviceid mints 9-digit device ids and decides which id a public key gets.
// A key keeps its id. device_id_claims records the key every id was ever given to; it lives in
// its own database file, which outlives any reset of the device registry, so an id is never
// given to a second key: a fresh id never repeats a claimed one, and a certified restore is
// honoured only for the key the id is claimed by (or for an id nobody claims). Without a
// certificate a new key always gets a fresh id, so asking for one reveals nothing.
package deviceid

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"

	"rc-signal/internal/sqlitex"
	protocol "rcprotocol"
)

var (
	ErrTaken   = errors.New("device id is taken")
	ErrClaimed = errors.New("device id is claimed by another key")
)

const allocationAttempts = 20

const claimsSchema = `
CREATE TABLE IF NOT EXISTS device_id_claims (
  device_id TEXT PRIMARY KEY,
  pubkey    TEXT NOT NULL
);`

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
		if err == nil {
			return Result{ID: certifiedID, Displaced: displaced}, nil
		}
		if !errors.Is(err, ErrClaimed) {
			return Result{}, err
		}
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

// OpenClaims opens the claims database at path and carries into it every claim the registry
// database db still knows: a device_id_claims table an earlier build kept there (then dropped)
// and one claim per device row. A claim already recorded is never changed.
func OpenClaims(path string, db *sql.DB) (*sql.DB, error) {
	claims, err := sqlitex.Open(path, claimsSchema)
	if err != nil {
		return nil, fmt.Errorf("claims database: %w", err)
	}
	if err := carryClaims(claims, db); err != nil {
		claims.Close()
		return nil, fmt.Errorf("claims database: %w", err)
	}
	return claims, nil
}

func carryClaims(claims, db *sql.DB) error {
	var legacy int
	if err := db.QueryRow(`SELECT COUNT(1) FROM sqlite_master WHERE type='table' AND name='device_id_claims'`).Scan(&legacy); err != nil {
		return err
	}
	sources := []string{`SELECT device_id, pubkey FROM devices WHERE pubkey <> ''`}
	if legacy > 0 {
		sources = append([]string{`SELECT device_id, pubkey FROM device_id_claims`}, sources...)
	}
	for _, query := range sources {
		if err := copyClaims(claims, db, query); err != nil {
			return err
		}
	}
	if legacy > 0 {
		_, err := db.Exec(`DROP TABLE device_id_claims`)
		return err
	}
	return nil
}

func copyClaims(claims, db *sql.DB, query string) error {
	rows, err := db.Query(query)
	if err != nil {
		return err
	}
	var pairs [][2]string
	for rows.Next() {
		var id, pubkey string
		if err := rows.Scan(&id, &pubkey); err != nil {
			rows.Close()
			return err
		}
		pairs = append(pairs, [2]string{id, pubkey})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	tx, err := claims.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, p := range pairs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO device_id_claims (device_id, pubkey) VALUES (?, ?)`, p[0], p[1]); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SQL is a Ledger over a registry database holding a devices(device_id, pubkey) table and a
// separate claims database from OpenClaims. Insert writes the new devices row; Evict removes
// another key's row for an id being restored to the key that claims it.
type SQL struct {
	DB     *sql.DB
	Claims *sql.DB
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

// Claim records the claim first, so a crash before the device row is written only wastes the id.
func (s SQL) Claim(id, pubkey string) error {
	if err := requireFree(s.DB, id, pubkey); err != nil {
		return err
	}
	res, err := s.Claims.Exec(`INSERT INTO device_id_claims (device_id, pubkey) VALUES (?, ?)
 ON CONFLICT(device_id) DO NOTHING`, id, pubkey)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrTaken
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := requireFree(tx, id, pubkey); err != nil {
		return err
	}
	if err := s.Insert(tx, id); err != nil {
		return err
	}
	return tx.Commit()
}

func (s SQL) Restore(id, pubkey string) (bool, error) {
	if _, err := s.Claims.Exec(`INSERT INTO device_id_claims (device_id, pubkey) VALUES (?, ?)
 ON CONFLICT(device_id) DO NOTHING`, id, pubkey); err != nil {
		return false, err
	}
	var claimant string
	if err := s.Claims.QueryRow(`SELECT pubkey FROM device_id_claims WHERE device_id = ?`, id).Scan(&claimant); err != nil {
		return false, err
	}
	if claimant != pubkey {
		return false, ErrClaimed
	}
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
	if err := s.Insert(tx, id); err != nil {
		return false, err
	}
	return displaced, tx.Commit()
}

type querier interface {
	QueryRow(query string, args ...any) *sql.Row
}

func requireFree(q querier, id, pubkey string) error {
	var n int
	if err := q.QueryRow(`SELECT COUNT(1) FROM devices WHERE device_id = ? OR pubkey = ?`, id, pubkey).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return ErrTaken
	}
	return nil
}
