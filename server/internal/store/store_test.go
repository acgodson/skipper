package store

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"rcprotocol"
)

func TestRegisterAndLookup(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_755_600_000, 0)

	d, existing, err := s.Register("PUBKEY-A", "Studio Mac", "", now)
	if err != nil {
		t.Fatal(err)
	}
	if existing {
		t.Fatal("a first registration reported existing=true")
	}
	if !protocol.ValidDeviceID(d.DeviceID) {
		t.Fatalf("deviceId %q is not 9 digits", d.DeviceID)
	}
	if d.Label != "Studio Mac" || d.CodeEpoch != 1 {
		t.Fatalf("stored device = %+v", d)
	}
	if !d.CreatedAt.Equal(now) || !d.UpdatedAt.Equal(now) {
		t.Fatalf("timestamps = %v/%v, want %v", d.CreatedAt, d.UpdatedAt, now)
	}

	again, existing, err := s.Register("PUBKEY-A", "renamed", "", now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !existing || again.DeviceID != d.DeviceID {
		t.Fatalf("re-register returned %q existing=%v, want %q true", again.DeviceID, existing, d.DeviceID)
	}

	seen := map[string]bool{d.DeviceID: true}
	for i := 0; i < 20; i++ {
		x, _, err := s.Register("PUBKEY-"+string(rune('a'+i)), "", "", now)
		if err != nil {
			t.Fatal(err)
		}
		if seen[x.DeviceID] {
			t.Fatalf("duplicate deviceId %q", x.DeviceID)
		}
		seen[x.DeviceID] = true
	}

	got, err := s.GetDevice(d.DeviceID)
	if err != nil || got.Pubkey != "PUBKEY-A" {
		t.Fatalf("GetDevice = %+v, %v", got, err)
	}
	byKey, err := s.GetByPubkey("PUBKEY-A")
	if err != nil || byKey.DeviceID != d.DeviceID {
		t.Fatalf("GetByPubkey = %+v, %v", byKey, err)
	}
	if _, err := s.GetDevice("000000000"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetDevice on a missing id: err = %v, want ErrNotFound", err)
	}
}

func TestBumpEpoch(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_755_600_000, 0)
	d, _, err := s.Register("PK", "", "", now)
	if err != nil {
		t.Fatal(err)
	}

	later := now.Add(90 * time.Second)
	if err := s.BumpEpoch(d.DeviceID, later); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetDevice(d.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if got.CodeEpoch != 2 {
		t.Fatalf("code epoch = %d, want 2", got.CodeEpoch)
	}
	if !got.UpdatedAt.Equal(later) || !got.CreatedAt.Equal(now) {
		t.Fatalf("timestamps = %v/%v", got.CreatedAt, got.UpdatedAt)
	}
	if err := s.BumpEpoch("000000000", later); !errors.Is(err, ErrNotFound) {
		t.Fatalf("BumpEpoch on a missing device: err = %v, want ErrNotFound", err)
	}
}

func TestMigrationDropsV1VerifierColumns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v1.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	const v1Schema = `CREATE TABLE devices (
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
	if _, err := db.Exec(v1Schema); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_755_600_000, 0)
	if _, err := db.Exec(`INSERT INTO devices VALUES
 ('481930275','PUBKEY-A','Studio Mac','argon2id','c2FsdA==','aGFzaA==',3,65536,1,32,7,?,?)`,
		now.UnixMilli(), now.UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("opening a v1 database: %v", err)
	}
	defer s.Close()

	d, err := s.GetDevice("481930275")
	if err != nil {
		t.Fatal(err)
	}
	if d.Pubkey != "PUBKEY-A" || d.Label != "Studio Mac" || d.CodeEpoch != 7 {
		t.Fatalf("migrated device = %+v", d)
	}
	if !d.CreatedAt.Equal(now) {
		t.Fatalf("createdAt = %v, want %v", d.CreatedAt, now)
	}
	var n int
	if err := s.db.QueryRow(
		`SELECT count(*) FROM pragma_table_info('devices') WHERE name LIKE 'code\_%' ESCAPE '\'`,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("code_* column count = %d, want 1 (code_epoch only)", n)
	}
	if _, _, err := s.Register("PUBKEY-B", "Laptop", "", now); err != nil {
		t.Fatalf("registering into a migrated database: %v", err)
	}
	if _, _, err := s.Register("PUBKEY-C", "", "481930275", now); err != nil {
		t.Fatal(err)
	}
	if got, err := s.GetByPubkey("PUBKEY-C"); err != nil || got.DeviceID == "481930275" {
		t.Fatalf("a migrated device's id must be claimed: %+v, %v", got, err)
	}
}

func TestRegisterPreferredDeviceID(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_755_600_000, 0)

	honoured, existing, err := s.Register("PK-A", "", "481930275", now)
	if err != nil || existing || honoured.DeviceID != "481930275" {
		t.Fatalf("a free preferred id for a new key = %+v existing=%v err=%v", honoured, existing, err)
	}

	known, existing, err := s.Register("PK-A", "", "222222222", now)
	if err != nil || !existing || known.DeviceID != "481930275" {
		t.Fatalf("a known key asking for another id = %+v existing=%v err=%v", known, existing, err)
	}

	stranger, existing, err := s.Register("PK-B", "", "481930275", now)
	if err != nil || existing || stranger.DeviceID == "481930275" || !protocol.ValidDeviceID(stranger.DeviceID) {
		t.Fatalf("a stranger asking for a held id = %+v existing=%v err=%v", stranger, existing, err)
	}

	if _, err := s.db.Exec(`DELETE FROM devices WHERE device_id = ?`, "481930275"); err != nil {
		t.Fatal(err)
	}
	tombstoned, _, err := s.Register("PK-C", "", "481930275", now)
	if err != nil || tombstoned.DeviceID == "481930275" {
		t.Fatalf("a tombstoned id went to another key: %+v err=%v", tombstoned, err)
	}
	back, existing, err := s.Register("PK-A", "", "481930275", now)
	if err != nil || existing || back.DeviceID != "481930275" {
		t.Fatalf("the original key could not reclaim its tombstoned id: %+v existing=%v err=%v", back, existing, err)
	}

	malformed, _, err := s.Register("PK-D", "", "12345", now)
	if err != nil || !protocol.ValidDeviceID(malformed.DeviceID) {
		t.Fatalf("a malformed preferred id = %+v err=%v", malformed, err)
	}
}

func TestWALModeEnabled(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir + "/rc.db")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var mode string
	if err := s.db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil {
		t.Fatal(err)
	}
	if mode != "wal" {
		t.Fatalf("journal_mode = %q, want wal", mode)
	}
}
