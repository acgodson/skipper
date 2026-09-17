package apidb

import (
	"database/sql"
	"errors"
	"path/filepath"
	"sync"
	"testing"

	"rc-signal/internal/deviceid"
	protocol "rcprotocol"
)

func open(t *testing.T) *DB {
	t.Helper()
	dir := t.TempDir()
	d, err := Open(filepath.Join(dir, "api.db"), filepath.Join(dir, "api-claims.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func register(t *testing.T, d *DB, pubkey, certified string) (*Device, deviceid.Result) {
	t.Helper()
	dev, result, err := d.RegisterDevice(Device{Pubkey: pubkey, CreatedAt: 1}, certified)
	if err != nil {
		t.Fatal(err)
	}
	return dev, result
}

func TestACertifiedRestoreNeverTakesAnIDClaimedByAnotherKey(t *testing.T) {
	d := open(t)
	holder, _ := register(t, d, "PK-HOLDER", "")
	other, res := register(t, d, "PK-OTHER", holder.DeviceID)
	if other.DeviceID == holder.DeviceID || res.Existing || res.Displaced || !protocol.ValidDeviceID(other.DeviceID) {
		t.Fatalf("a restore of another key's claimed id = %+v %+v", other, res)
	}
	if dev, res := register(t, d, "PK-HOLDER", "222222222"); !res.Existing || dev.DeviceID != holder.DeviceID {
		t.Fatalf("a key that holds an id keeps it: %+v %+v", dev, res)
	}
}

func TestARestoreToTheClaimantDisplacesAStaleRowAndRevokesItsTokens(t *testing.T) {
	d := open(t)
	const id = "481930275"
	if _, err := d.claims.Exec(`INSERT INTO device_id_claims (device_id, pubkey) VALUES (?, 'PK-OWNER')`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := d.db.Exec(`INSERT INTO devices (device_id, pubkey, created_at) VALUES (?, 'PK-STALE', 1)`, id); err != nil {
		t.Fatal(err)
	}
	if err := d.PutToken(DeviceToken{TokenHash: "h1", DeviceID: id, AccountID: "acct", ExpiresAt: 99}); err != nil {
		t.Fatal(err)
	}
	owner, res := register(t, d, "PK-OWNER", id)
	if owner.DeviceID != id || owner.Pubkey != "PK-OWNER" || res.Existing || !res.Displaced {
		t.Fatalf("restore = %+v %+v", owner, res)
	}
	if tok, err := d.TokenByHash("h1"); err != nil || !tok.Revoked {
		t.Fatalf("the stale row's token survived: %+v %v", tok, err)
	}
	if _, err := d.DeviceByPubkey("PK-STALE"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("the stale record survived: %v", err)
	}
}

func TestAPairIsKnownOnceItHadAMeteredSession(t *testing.T) {
	d := open(t)
	if known, err := d.PairKnown("111111111", "222222222"); err != nil || known {
		t.Fatalf("an unseen pair: %v %v", known, err)
	}
	if err := d.StartSession(Session{SessionID: "s1", HostDeviceID: "111111111", ControllerDeviceID: "222222222", StartedAt: 1}); err != nil {
		t.Fatal(err)
	}
	if known, err := d.PairKnown("111111111", "222222222"); err != nil || !known {
		t.Fatalf("a metered pair: %v %v", known, err)
	}
	if known, _ := d.PairKnown("222222222", "111111111"); known {
		t.Fatal("the reverse direction is not the same pair")
	}
}

func TestADeviceNonceIsSpentOnceAndOnlyByItsDevice(t *testing.T) {
	d := open(t)
	if err := d.PutNonce(Nonce{Nonce: "n1", DeviceID: "111111111", ExpiresAt: 100}); err != nil {
		t.Fatal(err)
	}
	if err := d.ConsumeDeviceNonce("n1", "222222222", 50); !errors.Is(err, ErrNotFound) {
		t.Fatalf("another device spent the nonce: %v", err)
	}
	if err := d.ConsumeDeviceNonce("n1", "111111111", 101); !errors.Is(err, ErrNotFound) {
		t.Fatalf("an expired nonce was spent: %v", err)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins := 0
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if d.ConsumeDeviceNonce("n1", "111111111", 50) == nil {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("the nonce was spent %d times", wins)
	}
}

func TestACodeNonceIsTheNewestLiveOneAndSpentOnce(t *testing.T) {
	d := open(t)
	for _, n := range []Nonce{
		{Nonce: "old", CodeHash: "c", ExpiresAt: 60},
		{Nonce: "new", CodeHash: "c", ExpiresAt: 90},
		{Nonce: "dev", DeviceID: "111111111", ExpiresAt: 95},
	} {
		if err := d.PutNonce(n); err != nil {
			t.Fatal(err)
		}
	}
	if got, err := d.ConsumeCodeNonce("c", 10); err != nil || got != "new" {
		t.Fatalf("first spend = %q %v, want new", got, err)
	}
	if got, err := d.ConsumeCodeNonce("c", 10); err != nil || got != "old" {
		t.Fatalf("second spend = %q %v, want old", got, err)
	}
	if _, err := d.ConsumeCodeNonce("c", 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a third spend found %v", err)
	}
	if _, err := d.ConsumeCodeNonce("", 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("an empty code hash matched a device nonce: %v", err)
	}
}

func TestMigrationDropsStoredCredentialsFromIdempotency(t *testing.T) {
	path := filepath.Join(t.TempDir(), "api.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`CREATE TABLE idempotency (scope TEXT NOT NULL, key TEXT NOT NULL, body_hash TEXT NOT NULL,
 status INTEGER NOT NULL DEFAULT 0, response BLOB, done INTEGER NOT NULL DEFAULT 0,
 created_at INTEGER NOT NULL, PRIMARY KEY (scope, key))`,
		`CREATE TABLE link_codes (code TEXT PRIMARY KEY, nonce TEXT NOT NULL)`,
		`INSERT INTO link_codes VALUES ('plaintext-code', 'n')`,
		`INSERT INTO idempotency VALUES ('ip:1|POST /v1/auth/device/token', 'k1', 'h', 200, '{"deviceToken":"SECRET"}', 1, 1)`,
		`INSERT INTO idempotency VALUES ('acct|POST /v1/auth/link', 'k2', 'h', 201, '{"code":"SECRET"}', 1, 1)`,
		`INSERT INTO idempotency VALUES ('acct|PATCH /v1/devices/1', 'k3', 'h', 200, '{"label":"x"}', 1, 1)`,
	} {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	raw.Close()

	d, err := Open(path, filepath.Join(filepath.Dir(path), "claims.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var leaked int
	if err := d.db.QueryRow(`SELECT COUNT(1) FROM idempotency WHERE CAST(response AS TEXT) LIKE '%SECRET%'`).Scan(&leaked); err != nil {
		t.Fatal(err)
	}
	if leaked != 0 {
		t.Fatalf("%d stored answers still hold a credential", leaked)
	}
	if rec, err := d.BeginIdempotent("acct|PATCH /v1/devices/1", "k3", "h", 2); err != nil || !rec.Replayable || string(rec.Response) != `{"label":"x"}` {
		t.Fatalf("an ordinary stored answer was lost: %+v %v", rec, err)
	}
	if rec, err := d.BeginIdempotent("ip:1|POST /v1/auth/device/token", "k1", "h", 2); err != nil || rec.Replayable || rec.Response != nil {
		t.Fatalf("a token answer is still replayable: %+v %v", rec, err)
	}
	var tables int
	if err := d.db.QueryRow(`SELECT COUNT(1) FROM sqlite_master WHERE name='link_codes'`).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("the plaintext link_codes table survived: %d %v", tables, err)
	}
}

func TestANonReplayableAnswerKeepsOnlyItsHash(t *testing.T) {
	d := open(t)
	if rec, err := d.BeginIdempotent("s", "k", "body", 1); err != nil || rec != nil {
		t.Fatalf("claim: %+v %v", rec, err)
	}
	if err := d.CompleteIdempotent("s", "k", 200, []byte(`{"deviceToken":"SECRET"}`), false); err != nil {
		t.Fatal(err)
	}
	var stored []byte
	var hash string
	if err := d.db.QueryRow(`SELECT response, response_hash FROM idempotency WHERE scope='s'`).Scan(&stored, &hash); err != nil {
		t.Fatal(err)
	}
	if stored != nil || len(hash) != 64 {
		t.Fatalf("stored body %q hash %q", stored, hash)
	}
}
