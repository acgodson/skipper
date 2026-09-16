package store

import (
	"errors"
	"testing"
	"time"

	"rcprotocol"
)

func verifier(hash string) protocol.CodeVerifier {
	return protocol.CodeVerifier{
		Alg: protocol.AlgArgon2id, Salt: "c2FsdHNhbHRzYWx0c2FsdA==", Hash: hash,
		Time: 3, MemKiB: 65536, Par: 1, Len: 32,
	}
}

func TestRegisterAndLookup(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_755_600_000, 0)

	d, existing, err := s.Register("PUBKEY-A", "Studio Mac", verifier("hash-a"), now)
	if err != nil {
		t.Fatal(err)
	}
	if existing {
		t.Fatal("a first registration reported existing=true")
	}
	if !protocol.ValidDeviceID(d.DeviceID) {
		t.Fatalf("deviceId %q is not 9 digits", d.DeviceID)
	}
	if d.Label != "Studio Mac" || d.Code.Hash != "hash-a" || d.CodeEpoch != 1 {
		t.Fatalf("stored device = %+v", d)
	}
	if !d.CreatedAt.Equal(now) || !d.UpdatedAt.Equal(now) {
		t.Fatalf("timestamps = %v/%v, want %v", d.CreatedAt, d.UpdatedAt, now)
	}

	// Idempotent per key, and the code is NOT overwritten.
	again, existing, err := s.Register("PUBKEY-A", "renamed", verifier("hash-z"), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !existing || again.DeviceID != d.DeviceID {
		t.Fatalf("re-register returned %q existing=%v, want %q true", again.DeviceID, existing, d.DeviceID)
	}
	if again.Code.Hash != "hash-a" {
		t.Fatalf("re-registration overwrote the stored verifier: %q", again.Code.Hash)
	}

	// Distinct keys get distinct ids.
	seen := map[string]bool{d.DeviceID: true}
	for i := 0; i < 20; i++ {
		x, _, err := s.Register("PUBKEY-"+string(rune('a'+i)), "", verifier("h"), now)
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

func TestUpdateCodeBumpsEpoch(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_755_600_000, 0)
	d, _, err := s.Register("PK", "", verifier("old"), now)
	if err != nil {
		t.Fatal(err)
	}

	later := now.Add(90 * time.Second)
	if err := s.UpdateCode(d.DeviceID, verifier("new"), later); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetDevice(d.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Code.Hash != "new" {
		t.Fatalf("code hash = %q, want %q", got.Code.Hash, "new")
	}
	if got.CodeEpoch != 2 {
		t.Fatalf("code epoch = %d, want 2", got.CodeEpoch)
	}
	if !got.UpdatedAt.Equal(later) || !got.CreatedAt.Equal(now) {
		t.Fatalf("timestamps = %v/%v", got.CreatedAt, got.UpdatedAt)
	}
	if err := s.UpdateCode("000000000", verifier("x"), later); !errors.Is(err, ErrNotFound) {
		t.Fatalf("UpdateCode on a missing device: err = %v, want ErrNotFound", err)
	}
	// An invalid verifier is refused and changes nothing.
	bad := verifier("nope")
	bad.MemKiB = 10
	if err := s.UpdateCode(d.DeviceID, bad, later); err == nil {
		t.Fatal("an out-of-range verifier was stored")
	}
	after, _ := s.GetDevice(d.DeviceID)
	if after.Code.Hash != "new" || after.CodeEpoch != 2 {
		t.Fatalf("a rejected update mutated state: %+v", after)
	}
}

func TestNewDeviceIDShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		id, err := NewDeviceID()
		if err != nil {
			t.Fatal(err)
		}
		if !protocol.ValidDeviceID(id) {
			t.Fatalf("id %q is not 9 digits", id)
		}
		if id[0] == '0' {
			t.Fatalf("id %q starts with 0", id)
		}
		seen[id] = true
	}
	if len(seen) < 190 {
		t.Fatalf("only %d unique ids out of 200 — generator is not random enough", len(seen))
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
