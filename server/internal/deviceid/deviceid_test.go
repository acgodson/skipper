package deviceid

import (
	"database/sql"
	"path/filepath"
	"testing"

	"rc-signal/internal/sqlitex"

	protocol "rcprotocol"
)

type memoryLedger struct {
	live   map[string]string
	claims map[string]string
}

func newMemoryLedger() *memoryLedger {
	return &memoryLedger{live: map[string]string{}, claims: map[string]string{}}
}

func (m *memoryLedger) IDForPubkey(pubkey string) (string, bool, error) {
	for id, pk := range m.live {
		if pk == pubkey {
			return id, true, nil
		}
	}
	return "", false, nil
}

func (m *memoryLedger) Claim(id, pubkey string) error {
	if _, ok := m.claims[id]; ok {
		return ErrTaken
	}
	if _, ok := m.live[id]; ok {
		return ErrTaken
	}
	m.claims[id] = pubkey
	m.live[id] = pubkey
	return nil
}

func (m *memoryLedger) Restore(id, pubkey string) (bool, error) {
	if claimant, ok := m.claims[id]; ok && claimant != pubkey {
		return false, ErrClaimed
	}
	owner, held := m.live[id]
	if held && owner == pubkey {
		return false, nil
	}
	m.claims[id] = pubkey
	m.live[id] = pubkey
	return held, nil
}

func TestWithoutACertificateANewKeyAlwaysGetsAFreshID(t *testing.T) {
	l := newMemoryLedger()
	first, err := Assign(l, "A", "")
	if err != nil || first.Existing || !protocol.ValidDeviceID(first.ID) {
		t.Fatalf("first key = %+v err=%v", first, err)
	}
	again, err := Assign(l, "A", "")
	if err != nil || !again.Existing || again.ID != first.ID {
		t.Fatalf("known key = %+v err=%v", again, err)
	}
	delete(l.live, first.ID)
	other, err := Assign(l, "B", "")
	if err != nil || other.ID == first.ID {
		t.Fatalf("a tombstoned id was reissued: %+v err=%v", other, err)
	}
}

func TestACertifiedIDIsRestoredOnlyToTheKeyItIsClaimedBy(t *testing.T) {
	l := newMemoryLedger()
	l.claims["111111111"] = "owner"
	l.live["111111111"] = "squatter"
	got, err := Assign(l, "owner", "111111111")
	if err != nil || got.ID != "111111111" || got.Existing || !got.Displaced {
		t.Fatalf("restore = %+v err=%v", got, err)
	}
	if l.live["111111111"] != "owner" {
		t.Fatalf("the id still belongs to %q", l.live["111111111"])
	}
	free, err := Assign(l, "other", "222222222")
	if err != nil || free.ID != "222222222" || free.Displaced {
		t.Fatalf("restore of a free id = %+v err=%v", free, err)
	}
	kept, err := Assign(l, "owner", "333333333")
	if err != nil || !kept.Existing || kept.ID != "111111111" {
		t.Fatalf("a key that holds an id keeps it = %+v err=%v", kept, err)
	}
	l.claims["444444444"] = "first"
	second, err := Assign(l, "second", "444444444")
	if err != nil || second.ID == "444444444" || second.Displaced || l.claims["444444444"] != "first" {
		t.Fatalf("a restore of an id claimed by another key = %+v err=%v", second, err)
	}
	if _, err := Assign(l, "x", "12ab"); err == nil {
		t.Fatal("a malformed certified id was accepted")
	}
}

func TestNewShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		id, err := New()
		if err != nil {
			t.Fatal(err)
		}
		if !protocol.ValidDeviceID(id) || id[0] == '0' {
			t.Fatalf("id %q is not 9 digits without a leading 0", id)
		}
		seen[id] = true
	}
	if len(seen) < 190 {
		t.Fatalf("only %d unique ids out of 200", len(seen))
	}
}

type sqlLedger struct {
	SQL
	registering string
}

func openSQLLedger(t *testing.T, mainPath, claimsPath string) *sqlLedger {
	t.Helper()
	db, err := sqlitex.Open(mainPath, `CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, pubkey TEXT NOT NULL UNIQUE)`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	claims, err := OpenClaims(claimsPath, db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { claims.Close() })
	l := &sqlLedger{}
	l.SQL = SQL{
		DB: db, Claims: claims,
		Insert: func(tx *sql.Tx, id string) error {
			_, err := tx.Exec(`INSERT INTO devices (device_id, pubkey) VALUES (?, ?)`, id, l.registering)
			return err
		},
		Evict: func(tx *sql.Tx, id string) error {
			_, err := tx.Exec(`DELETE FROM devices WHERE device_id = ?`, id)
			return err
		},
	}
	return l
}

func assignSQL(t *testing.T, l *sqlLedger, pubkey, certified string) Result {
	t.Helper()
	l.registering = pubkey
	got, err := Assign(l.SQL, pubkey, certified)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestClaimsOutliveARegistryResetAndAreNeverReassigned(t *testing.T) {
	dir := t.TempDir()
	claimsPath := filepath.Join(dir, "claims.db")
	before := openSQLLedger(t, filepath.Join(dir, "one.db"), claimsPath)
	owner := assignSQL(t, before, "owner", "")
	before.DB.Close()
	before.Claims.Close()

	after := openSQLLedger(t, filepath.Join(dir, "two.db"), claimsPath)
	if got := assignSQL(t, after, "squatter", owner.ID); got.ID == owner.ID {
		t.Fatalf("a claimed id went to another key after a registry reset: %+v", got)
	}
	for i := 0; i < 50; i++ {
		if got := assignSQL(t, after, "fresh-"+string(rune('A'+i)), ""); got.ID == owner.ID {
			t.Fatal("a fresh id repeated a claimed one")
		}
	}
	if got := assignSQL(t, after, "owner", owner.ID); got.ID != owner.ID || got.Existing {
		t.Fatalf("the claimant's certified restore = %+v", got)
	}

	if _, err := after.DB.Exec(`DELETE FROM devices WHERE device_id = ?`, owner.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := after.DB.Exec(`INSERT INTO devices (device_id, pubkey) VALUES (?, 'stale')`, owner.ID); err != nil {
		t.Fatal(err)
	}
	if got := assignSQL(t, after, "owner", owner.ID); got.ID != owner.ID || !got.Displaced {
		t.Fatalf("a stale row under the claimed id was not displaced: %+v", got)
	}
}

func TestLegacyClaimsAreCarriedIntoTheClaimsDatabase(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "main.db")
	legacy, err := sqlitex.Open(mainPath, `
CREATE TABLE devices (device_id TEXT PRIMARY KEY, pubkey TEXT NOT NULL UNIQUE);
CREATE TABLE device_id_claims (device_id TEXT PRIMARY KEY, pubkey TEXT NOT NULL);
INSERT INTO devices VALUES ('111111111', 'live');
INSERT INTO device_id_claims VALUES ('222222222', 'removed');`)
	if err != nil {
		t.Fatal(err)
	}
	legacy.Close()
	l := openSQLLedger(t, mainPath, filepath.Join(dir, "claims.db"))
	for id, key := range map[string]string{"111111111": "live", "222222222": "removed"} {
		var got string
		if err := l.Claims.QueryRow(`SELECT pubkey FROM device_id_claims WHERE device_id = ?`, id).Scan(&got); err != nil || got != key {
			t.Fatalf("claim %s = %q err=%v, want %q", id, got, err, key)
		}
	}
	var left int
	if err := l.DB.QueryRow(`SELECT COUNT(1) FROM sqlite_master WHERE name='device_id_claims'`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("the legacy claims table is still in the registry database: %d %v", left, err)
	}
}
