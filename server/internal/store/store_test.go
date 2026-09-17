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
	s, err := Open(":memory:", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_755_600_000, 0)

	d, first, err := s.Register("PUBKEY-A", "Studio Mac", "", now)
	if err != nil {
		t.Fatal(err)
	}
	if first.Existing {
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

	again, second, err := s.Register("PUBKEY-A", "renamed", "", now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !second.Existing || again.DeviceID != d.DeviceID {
		t.Fatalf("re-register returned %q existing=%v, want %q true", again.DeviceID, second.Existing, d.DeviceID)
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
	s, err := Open(":memory:", ":memory:")
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

	s, err := Open(path, filepath.Join(filepath.Dir(path), "claims.db"))
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
	if _, _, err := s.Register("PUBKEY-C", "", "", now); err != nil {
		t.Fatal(err)
	}
	if got, err := s.GetByPubkey("PUBKEY-C"); err != nil || got.DeviceID == "481930275" {
		t.Fatalf("a migrated device's id must be claimed: %+v, %v", got, err)
	}
}

func TestAClaimedDeviceIDSurvivesARegistryResetAndIsNeverHandedToAnotherKey(t *testing.T) {
	dir := t.TempDir()
	claims := filepath.Join(dir, "claims.db")
	now := time.Unix(1_755_600_000, 0)
	before, err := Open(filepath.Join(dir, "one.db"), claims)
	if err != nil {
		t.Fatal(err)
	}
	owner, _, err := before.Register("PK-OWNER", "", "", now)
	if err != nil {
		t.Fatal(err)
	}
	before.Close()

	s, err := Open(filepath.Join(dir, "two.db"), claims)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	squat, res, err := s.Register("PK-SQUAT", "", owner.DeviceID, now)
	if err != nil || res.Displaced || squat.DeviceID == owner.DeviceID {
		t.Fatalf("a claimed id went to another key after the reset: %+v %+v err=%v", squat, res, err)
	}
	restored, res, err := s.Register("PK-OWNER", "", owner.DeviceID, now)
	if err != nil || res.Existing || restored.DeviceID != owner.DeviceID || restored.Pubkey != "PK-OWNER" {
		t.Fatalf("the claimant's certified restore = %+v %+v err=%v", restored, res, err)
	}
	known, res, err := s.Register("PK-OWNER", "", "222222222", now)
	if err != nil || !res.Existing || known.DeviceID != owner.DeviceID {
		t.Fatalf("a key that holds an id keeps it = %+v %+v err=%v", known, res, err)
	}
	again, res, err := s.Register("PK-SQUAT", "", owner.DeviceID, now)
	if err != nil || !res.Existing || again.DeviceID != squat.DeviceID {
		t.Fatalf("the other key re-registering = %+v %+v err=%v", again, res, err)
	}
}

func TestKnownPairsAreDurable(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir+"/rc.db", dir+"/claims.db")
	if err != nil {
		t.Fatal(err)
	}
	if known, err := s.KnownPair("111111111", "222222222"); err != nil || known {
		t.Fatalf("an unseen pair is known: %v %v", known, err)
	}
	for i := 0; i < 2; i++ {
		if err := s.RecordPair("111111111", "222222222", time.Unix(1_755_600_000, 0)); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	s, err = Open(dir+"/rc.db", dir+"/claims.db")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if known, err := s.KnownPair("111111111", "222222222"); err != nil || !known {
		t.Fatalf("a recorded pair was forgotten: %v %v", known, err)
	}
	if known, _ := s.KnownPair("222222222", "111111111"); known {
		t.Fatal("a pair is directional: host and controller are not interchangeable")
	}
}

func TestWALModeEnabled(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir+"/rc.db", dir+"/claims.db")
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
