// Package apidb is the rc-api SQLite store: accounts, devices, link codes,
// device tokens, session accounting, the append-only credit ledger and gifts.
// It holds no raw hardware id, no plaintext device token and no session content.
package apidb

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	protocol "rcprotocol"
)

var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("conflict")
)

type Account struct {
	AccountID string
	Email     string
	CreatedAt int64
	Suspended bool
}

type Device struct {
	DeviceID     string
	AccountID    string
	Label        string
	Platform     string
	Pubkey       string
	HardwareHash string
	CreatedAt    int64
	LinkedAt     int64
	LastSeen     int64
	TrialEndsAt  int64
	Unlinked     bool
	CodeEpoch    int64
}

func (d Device) Public() protocol.Device {
	return protocol.Device{
		DeviceID:    d.DeviceID,
		Label:       d.Label,
		Platform:    d.Platform,
		Pubkey:      d.Pubkey,
		CreatedAt:   d.CreatedAt,
		LinkedAt:    d.LinkedAt,
		LastSeen:    d.LastSeen,
		TrialEndsAt: d.TrialEndsAt,
	}
}

type LinkCode struct {
	Code      string
	Nonce     string
	Pubkey    string
	Platform  string
	Label     string
	AccountID string
	ExpiresAt int64
	Used      bool
}

type Nonce struct {
	Nonce     string
	Code      string
	DeviceID  string
	ExpiresAt int64
	Used      bool
}

type DeviceToken struct {
	TokenHash string
	DeviceID  string
	AccountID string
	IssuedAt  int64
	ExpiresAt int64
	Revoked   bool
}

type Session struct {
	SessionID          string
	HostDeviceID       string
	ControllerDeviceID string
	HostAccountID      string
	StartedAt          int64
	EndedAt            *int64
	RelayUsed          bool
	BytesRelayed       *int64
	Reason             string
}

type Gift struct {
	GiftID        string
	FromAccountID string
	FromEmail     string
	ToEmail       string
	AmountCents   int64
	Message       string
	Status        string
	CreatedAt     int64
	ExpiresAt     int64
	AcceptedAt    *int64
}

func (g Gift) Public() protocol.Gift {
	return protocol.Gift{
		GiftID:      g.GiftID,
		Status:      g.Status,
		AmountCents: g.AmountCents,
		ToEmail:     g.ToEmail,
		FromEmail:   g.FromEmail,
		Message:     g.Message,
		CreatedAt:   g.CreatedAt,
		ExpiresAt:   g.ExpiresAt,
		AcceptedAt:  g.AcceptedAt,
	}
}

type Idempotent struct {
	BodyHash string
	Status   int
	Response []byte
	Done     bool
}

type DB struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS accounts (
  account_id TEXT PRIMARY KEY,
  email      TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  suspended  INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS devices (
  device_id     TEXT PRIMARY KEY,
  account_id    TEXT NOT NULL DEFAULT '',
  label         TEXT NOT NULL DEFAULT '',
  platform      TEXT NOT NULL DEFAULT '',
  pubkey        TEXT NOT NULL DEFAULT '',
  hardware_hash TEXT NOT NULL DEFAULT '',
  created_at    INTEGER NOT NULL,
  linked_at     INTEGER NOT NULL DEFAULT 0,
  last_seen     INTEGER NOT NULL DEFAULT 0,
  trial_ends_at INTEGER NOT NULL DEFAULT 0,
  unlinked      INTEGER NOT NULL DEFAULT 0,
  code_epoch    INTEGER NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX IF NOT EXISTS devices_pubkey ON devices(pubkey) WHERE pubkey <> '';
CREATE INDEX IF NOT EXISTS devices_account ON devices(account_id);
CREATE INDEX IF NOT EXISTS devices_hardware ON devices(hardware_hash);
CREATE TABLE IF NOT EXISTS link_codes (
  code       TEXT PRIMARY KEY,
  nonce      TEXT NOT NULL,
  pubkey     TEXT NOT NULL,
  platform   TEXT NOT NULL,
  label      TEXT NOT NULL DEFAULT '',
  account_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used       INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS nonces (
  nonce      TEXT PRIMARY KEY,
  code       TEXT NOT NULL DEFAULT '',
  device_id  TEXT NOT NULL DEFAULT '',
  expires_at INTEGER NOT NULL,
  used       INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS device_tokens (
  token_hash TEXT PRIMARY KEY,
  device_id  TEXT NOT NULL,
  account_id TEXT NOT NULL,
  issued_at  INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS tokens_device ON device_tokens(device_id);
CREATE TABLE IF NOT EXISTS sessions (
  session_id           TEXT PRIMARY KEY,
  host_device_id       TEXT NOT NULL,
  controller_device_id TEXT NOT NULL,
  host_account_id      TEXT NOT NULL DEFAULT '',
  started_at           INTEGER NOT NULL,
  ended_at             INTEGER,
  relay_used           INTEGER NOT NULL DEFAULT 0,
  bytes_relayed        INTEGER,
  reason               TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS sessions_host ON sessions(host_device_id);
CREATE INDEX IF NOT EXISTS sessions_controller ON sessions(controller_device_id);
CREATE TABLE IF NOT EXISTS ledger (
  entry_id            TEXT PRIMARY KEY,
  account_id          TEXT NOT NULL,
  type                TEXT NOT NULL,
  amount_cents        INTEGER NOT NULL,
  balance_after_cents INTEGER NOT NULL,
  created_at          INTEGER NOT NULL,
  session_id          TEXT NOT NULL DEFAULT '',
  gift_id             TEXT NOT NULL DEFAULT '',
  memo                TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS ledger_account ON ledger(account_id, created_at);
CREATE TABLE IF NOT EXISTS gifts (
  gift_id         TEXT PRIMARY KEY,
  from_account_id TEXT NOT NULL,
  from_email      TEXT NOT NULL,
  to_email        TEXT NOT NULL,
  amount_cents    INTEGER NOT NULL,
  message         TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  expires_at      INTEGER NOT NULL,
  accepted_at     INTEGER
);
CREATE INDEX IF NOT EXISTS gifts_from ON gifts(from_account_id);
CREATE INDEX IF NOT EXISTS gifts_to ON gifts(to_email);
CREATE TABLE IF NOT EXISTS idempotency (
  scope      TEXT NOT NULL,
  key        TEXT NOT NULL,
  body_hash  TEXT NOT NULL,
  status     INTEGER NOT NULL DEFAULT 0,
  response   BLOB,
  done       INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (scope, key)
);`

func Open(path string) (*DB, error) {
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
	if err := addColumnIfMissing(db, "devices", "code_epoch", "INTEGER NOT NULL DEFAULT 1"); err != nil {
		db.Close()
		return nil, err
	}
	return &DB{db: db}, nil
}

func addColumnIfMissing(db *sql.DB, table, column, decl string) error {
	var n int
	err := db.QueryRow(`SELECT COUNT(1) FROM pragma_table_info(?) WHERE name=?`, table, column).Scan(&n)
	if err != nil || n > 0 {
		return err
	}
	_, err = db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + decl)
	return err
}

func (d *DB) Close() error { return d.db.Close() }

func NewID(prefix string) string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(b)
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

func NormaliseEmail(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

// --- accounts ---------------------------------------------------------------

const accountCols = `account_id, email, created_at, suspended`

func scanAccount(row interface{ Scan(...any) error }) (*Account, error) {
	var a Account
	var suspended int
	err := row.Scan(&a.AccountID, &a.Email, &a.CreatedAt, &suspended)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	a.Suspended = suspended != 0
	return &a, nil
}

func (d *DB) AccountByID(id string) (*Account, error) {
	return scanAccount(d.db.QueryRow(`SELECT `+accountCols+` FROM accounts WHERE account_id=?`, id))
}

func (d *DB) AccountByEmail(email string) (*Account, error) {
	return scanAccount(d.db.QueryRow(`SELECT `+accountCols+` FROM accounts WHERE email=?`, NormaliseEmail(email)))
}

// EnsureAccount upserts the account an identity provider just vouched for.
func (d *DB) EnsureAccount(accountID, email string, now time.Time) (*Account, error) {
	email = NormaliseEmail(email)
	if a, err := d.AccountByEmail(email); err == nil {
		return a, nil
	} else if !errors.Is(err, ErrNotFound) {
		return nil, err
	}
	if accountID == "" {
		accountID = NewID("acct_")
	}
	_, err := d.db.Exec(`INSERT INTO accounts (account_id, email, created_at, suspended)
 VALUES (?,?,?,0) ON CONFLICT(account_id) DO UPDATE SET email=excluded.email`,
		accountID, email, now.UnixMilli())
	if err != nil {
		return nil, err
	}
	return d.AccountByID(accountID)
}

// --- devices ----------------------------------------------------------------

const deviceCols = `device_id, account_id, label, platform, pubkey, hardware_hash,
 created_at, linked_at, last_seen, trial_ends_at, unlinked, code_epoch`

func scanDevice(row interface{ Scan(...any) error }) (*Device, error) {
	var dev Device
	var unlinked int
	err := row.Scan(&dev.DeviceID, &dev.AccountID, &dev.Label, &dev.Platform, &dev.Pubkey,
		&dev.HardwareHash, &dev.CreatedAt, &dev.LinkedAt, &dev.LastSeen, &dev.TrialEndsAt, &unlinked, &dev.CodeEpoch)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	dev.Unlinked = unlinked != 0
	return &dev, nil
}

func (d *DB) DeviceByID(id string) (*Device, error) {
	return scanDevice(d.db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE device_id=?`, id))
}

func (d *DB) DeviceByPubkey(pubkey string) (*Device, error) {
	return scanDevice(d.db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE pubkey=?`, pubkey))
}

func (d *DB) exists(query string, args ...any) (bool, error) {
	var n int
	if err := d.db.QueryRow(query, args...).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

func (d *DB) PubkeySeen(pubkey string) (bool, error) {
	return d.exists(`SELECT COUNT(1) FROM devices WHERE pubkey=? AND pubkey<>''`, pubkey)
}

func (d *DB) HardwareSeen(hash string) (bool, error) {
	return d.exists(`SELECT COUNT(1) FROM devices WHERE hardware_hash=? AND hardware_hash<>''`, hash)
}

func (d *DB) InsertDevice(dev Device) error {
	_, err := d.db.Exec(`INSERT INTO devices
 (device_id, account_id, label, platform, pubkey, hardware_hash, created_at, linked_at, last_seen, trial_ends_at, unlinked)
 VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
		dev.DeviceID, dev.AccountID, dev.Label, dev.Platform, dev.Pubkey, dev.HardwareHash,
		dev.CreatedAt, dev.LinkedAt, dev.LastSeen, dev.TrialEndsAt, boolInt(dev.Unlinked))
	return err
}

// RegisterDevice is idempotent by pubkey: a known key returns its record and existing=true.
func (d *DB) RegisterDevice(dev Device) (*Device, bool, error) {
	if dev.Pubkey == "" {
		return nil, false, errors.New("a device needs a public key")
	}
	if found, err := d.DeviceByPubkey(dev.Pubkey); err == nil {
		return found, true, nil
	} else if !errors.Is(err, ErrNotFound) {
		return nil, false, err
	}
	for attempt := 0; attempt < 20; attempt++ {
		id, err := NewDeviceID()
		if err != nil {
			return nil, false, err
		}
		dev.DeviceID = id
		if err := d.InsertDevice(dev); err == nil {
			created, err := d.DeviceByID(id)
			return created, false, err
		}
		if found, err := d.DeviceByPubkey(dev.Pubkey); err == nil {
			return found, true, nil
		}
	}
	return nil, false, errors.New("could not allocate a unique device id")
}

func (d *DB) BumpEpoch(deviceID string) (*Device, error) {
	res, err := d.db.Exec(`UPDATE devices SET code_epoch=code_epoch+1 WHERE device_id=?`, deviceID)
	if err != nil {
		return nil, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return nil, err
	} else if n == 0 {
		return nil, ErrNotFound
	}
	return d.DeviceByID(deviceID)
}

// ExpireTrials ends every running trial on the account's devices.
// TODO: remove with the dev-only /v1/dev/expire-trial endpoint at launch.
func (d *DB) ExpireTrials(accountID string, now int64) error {
	_, err := d.db.Exec(`UPDATE devices SET trial_ends_at=? WHERE account_id=? AND trial_ends_at>?`,
		now-1, accountID, now)
	return err
}

func (d *DB) UpdateDeviceLink(deviceID, accountID, label, platform, hardwareHash string, trialEndsAt, now int64) error {
	_, err := d.db.Exec(`UPDATE devices SET account_id=?, label=?, platform=?,
 hardware_hash=CASE WHEN hardware_hash='' THEN ? ELSE hardware_hash END,
 trial_ends_at=CASE WHEN trial_ends_at=0 THEN ? ELSE trial_ends_at END,
 linked_at=?, last_seen=?, unlinked=0 WHERE device_id=?`,
		accountID, label, platform, hardwareHash, trialEndsAt, now, now, deviceID)
	return err
}

func (d *DB) SetLabel(deviceID, label string) error {
	_, err := d.db.Exec(`UPDATE devices SET label=? WHERE device_id=?`, label, deviceID)
	return err
}

func (d *DB) TouchDevice(deviceID string, now int64) error {
	_, err := d.db.Exec(`UPDATE devices SET last_seen=? WHERE device_id=?`, now, deviceID)
	return err
}

func (d *DB) UnlinkDevice(deviceID string) error {
	if _, err := d.db.Exec(`UPDATE devices SET unlinked=1, account_id='' WHERE device_id=?`, deviceID); err != nil {
		return err
	}
	_, err := d.db.Exec(`UPDATE device_tokens SET revoked=1 WHERE device_id=?`, deviceID)
	return err
}

func (d *DB) ListDevices(accountID string, after string, limit int) ([]Device, error) {
	rows, err := d.db.Query(`SELECT `+deviceCols+` FROM devices
 WHERE account_id=? AND unlinked=0 AND device_id > ? ORDER BY device_id LIMIT ?`,
		accountID, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		dev, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *dev)
	}
	return out, rows.Err()
}

// --- link codes and nonces --------------------------------------------------

func (d *DB) PutLinkCode(c LinkCode) error {
	_, err := d.db.Exec(`INSERT INTO link_codes (code, nonce, pubkey, platform, label, account_id, expires_at, used)
 VALUES (?,?,?,?,?,?,?,0)`, c.Code, c.Nonce, c.Pubkey, c.Platform, c.Label, c.AccountID, c.ExpiresAt)
	return err
}

func (d *DB) LinkCodeByCode(code string) (*LinkCode, error) {
	var c LinkCode
	var used int
	err := d.db.QueryRow(`SELECT code, nonce, pubkey, platform, label, account_id, expires_at, used
 FROM link_codes WHERE code=?`, code).
		Scan(&c.Code, &c.Nonce, &c.Pubkey, &c.Platform, &c.Label, &c.AccountID, &c.ExpiresAt, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	c.Used = used != 0
	return &c, nil
}

func (d *DB) UseLinkCode(code string) error {
	res, err := d.db.Exec(`UPDATE link_codes SET used=1 WHERE code=? AND used=0`, code)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrConflict
	}
	return nil
}

func (d *DB) PutNonce(n Nonce) error {
	_, err := d.db.Exec(`INSERT INTO nonces (nonce, code, device_id, expires_at, used) VALUES (?,?,?,?,0)`,
		n.Nonce, n.Code, n.DeviceID, n.ExpiresAt)
	return err
}

// ConsumeNonce returns the nonce exactly once; a replay is ErrNotFound.
func (d *DB) ConsumeNonce(nonce string, now int64) (*Nonce, error) {
	var n Nonce
	var used int
	err := d.db.QueryRow(`SELECT nonce, code, device_id, expires_at, used FROM nonces WHERE nonce=?`, nonce).
		Scan(&n.Nonce, &n.Code, &n.DeviceID, &n.ExpiresAt, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if used != 0 || n.ExpiresAt < now {
		return nil, ErrNotFound
	}
	if _, err := d.db.Exec(`UPDATE nonces SET used=1 WHERE nonce=?`, nonce); err != nil {
		return nil, err
	}
	return &n, nil
}

// LatestNonce finds the live challenge nonce issued for a link code or a device.
func (d *DB) LatestNonce(code, deviceID string, now int64) (*Nonce, error) {
	column, value := "code", code
	if code == "" {
		column, value = "device_id", deviceID
	}
	var n Nonce
	var used int
	err := d.db.QueryRow(`SELECT nonce, code, device_id, expires_at, used FROM nonces
 WHERE `+column+`=? AND `+column+`<>'' AND used=0 AND expires_at >= ?
 ORDER BY expires_at DESC LIMIT 1`, value, now).
		Scan(&n.Nonce, &n.Code, &n.DeviceID, &n.ExpiresAt, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &n, nil
}

func (d *DB) PurgeExpired(now int64) error {
	for _, q := range []string{
		`DELETE FROM nonces WHERE expires_at < ?`,
		`DELETE FROM link_codes WHERE expires_at < ?`,
	} {
		if _, err := d.db.Exec(q, now); err != nil {
			return err
		}
	}
	_, err := d.db.Exec(`DELETE FROM idempotency WHERE created_at < ?`,
		now-int64(protocol.IdempotencyRetentionSec)*1000)
	return err
}

// --- device tokens ----------------------------------------------------------

func (d *DB) PutToken(t DeviceToken) error {
	_, err := d.db.Exec(`INSERT INTO device_tokens (token_hash, device_id, account_id, issued_at, expires_at, revoked)
 VALUES (?,?,?,?,?,0)`, t.TokenHash, t.DeviceID, t.AccountID, t.IssuedAt, t.ExpiresAt)
	return err
}

func (d *DB) TokenByHash(hash string) (*DeviceToken, error) {
	var t DeviceToken
	var revoked int
	err := d.db.QueryRow(`SELECT token_hash, device_id, account_id, issued_at, expires_at, revoked
 FROM device_tokens WHERE token_hash=?`, hash).
		Scan(&t.TokenHash, &t.DeviceID, &t.AccountID, &t.IssuedAt, &t.ExpiresAt, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	t.Revoked = revoked != 0
	return &t, nil
}

func (d *DB) RevokeToken(hash string) error {
	_, err := d.db.Exec(`UPDATE device_tokens SET revoked=1 WHERE token_hash=?`, hash)
	return err
}

// --- sessions ---------------------------------------------------------------

const sessionCols = `session_id, host_device_id, controller_device_id, host_account_id,
 started_at, ended_at, relay_used, bytes_relayed, reason`

func scanSession(row interface{ Scan(...any) error }) (*Session, error) {
	var s Session
	var relay int
	var ended, bytes sql.NullInt64
	err := row.Scan(&s.SessionID, &s.HostDeviceID, &s.ControllerDeviceID, &s.HostAccountID,
		&s.StartedAt, &ended, &relay, &bytes, &s.Reason)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	s.RelayUsed = relay != 0
	if ended.Valid {
		v := ended.Int64
		s.EndedAt = &v
	}
	if bytes.Valid {
		v := bytes.Int64
		s.BytesRelayed = &v
	}
	return &s, nil
}

func (d *DB) StartSession(s Session) error {
	_, err := d.db.Exec(`INSERT INTO sessions
 (session_id, host_device_id, controller_device_id, host_account_id, started_at, relay_used, reason)
 VALUES (?,?,?,?,?,0,'') ON CONFLICT(session_id) DO NOTHING`,
		s.SessionID, s.HostDeviceID, s.ControllerDeviceID, s.HostAccountID, s.StartedAt)
	return err
}

func (d *DB) SessionByID(id string) (*Session, error) {
	return scanSession(d.db.QueryRow(`SELECT `+sessionCols+` FROM sessions WHERE session_id=?`, id))
}

func (d *DB) StopSession(id string, endedAt int64, relayUsed bool, bytesRelayed *int64, reason string) error {
	res, err := d.db.Exec(`UPDATE sessions SET ended_at=?, relay_used=?, bytes_relayed=?, reason=?
 WHERE session_id=? AND ended_at IS NULL`, endedAt, boolInt(relayUsed), bytesRelayed, reason, id)
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

// OpenSessionsForAccount counts live sessions the account holds through any host
// device other than the one asking.
func (d *DB) OpenSessionsForAccount(accountID, exceptHostDeviceID string) (int, error) {
	var n int
	err := d.db.QueryRow(`SELECT COUNT(1) FROM sessions
 WHERE host_account_id=? AND host_account_id<>'' AND ended_at IS NULL AND host_device_id<>?`,
		accountID, exceptHostDeviceID).Scan(&n)
	return n, err
}

type SessionQuery struct {
	DeviceIDs []string
	Since     int64
	Until     int64
	After     int64
	AfterID   string
	Limit     int
}

func (d *DB) ListSessions(q SessionQuery) ([]Session, error) {
	if len(q.DeviceIDs) == 0 {
		return nil, nil
	}
	args := []any{}
	placeholders := make([]string, 0, len(q.DeviceIDs))
	for _, id := range q.DeviceIDs {
		placeholders = append(placeholders, "?")
		args = append(args, id)
	}
	in := strings.Join(placeholders, ",")
	where := `(host_device_id IN (` + in + `) OR controller_device_id IN (` + in + `))`
	args = append(args, args...)
	where += ` AND started_at >= ?`
	args = append(args, q.Since)
	if q.Until > 0 {
		where += ` AND started_at <= ?`
		args = append(args, q.Until)
	}
	if q.After > 0 {
		where += ` AND (started_at < ? OR (started_at = ? AND session_id > ?))`
		args = append(args, q.After, q.After, q.AfterID)
	}
	args = append(args, q.Limit)
	rows, err := d.db.Query(`SELECT `+sessionCols+` FROM sessions WHERE `+where+
		` ORDER BY started_at DESC, session_id ASC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Session
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

// --- ledger -----------------------------------------------------------------

func (d *DB) Balance(accountID string) (int64, error) {
	if accountID == "" {
		return 0, nil
	}
	var sum sql.NullInt64
	err := d.db.QueryRow(`SELECT SUM(amount_cents) FROM ledger WHERE account_id=?`, accountID).Scan(&sum)
	if err != nil {
		return 0, err
	}
	return sum.Int64, nil
}

func (d *DB) BalanceUpdatedAt(accountID string) (int64, error) {
	var at sql.NullInt64
	err := d.db.QueryRow(`SELECT MAX(created_at) FROM ledger WHERE account_id=?`, accountID).Scan(&at)
	return at.Int64, err
}

// Append writes one ledger entry and returns it with the balance it produced.
func (d *DB) Append(accountID, entryType string, amountCents int64, now int64, sessionID, giftID, memo string) (protocol.LedgerEntry, error) {
	balance, err := d.Balance(accountID)
	if err != nil {
		return protocol.LedgerEntry{}, err
	}
	entry := protocol.LedgerEntry{
		EntryID:           NewID("led_"),
		Type:              entryType,
		AmountCents:       amountCents,
		BalanceAfterCents: balance + amountCents,
		CreatedAt:         now,
		SessionID:         sessionID,
		GiftID:            giftID,
		Memo:              memo,
	}
	_, err = d.db.Exec(`INSERT INTO ledger
 (entry_id, account_id, type, amount_cents, balance_after_cents, created_at, session_id, gift_id, memo)
 VALUES (?,?,?,?,?,?,?,?,?)`, entry.EntryID, accountID, entry.Type, entry.AmountCents,
		entry.BalanceAfterCents, entry.CreatedAt, entry.SessionID, entry.GiftID, entry.Memo)
	return entry, err
}

type LedgerQuery struct {
	AccountID string
	Since     int64
	Until     int64
	After     int64
	AfterID   string
	Limit     int
}

func (d *DB) ListLedger(q LedgerQuery) ([]protocol.LedgerEntry, error) {
	args := []any{q.AccountID, q.Since}
	where := `account_id=? AND created_at >= ?`
	if q.Until > 0 {
		where += ` AND created_at <= ?`
		args = append(args, q.Until)
	}
	if q.After > 0 {
		where += ` AND (created_at < ? OR (created_at = ? AND entry_id > ?))`
		args = append(args, q.After, q.After, q.AfterID)
	}
	args = append(args, q.Limit)
	rows, err := d.db.Query(`SELECT entry_id, type, amount_cents, balance_after_cents, created_at,
 session_id, gift_id, memo FROM ledger WHERE `+where+
		` ORDER BY created_at DESC, entry_id ASC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []protocol.LedgerEntry
	for rows.Next() {
		var e protocol.LedgerEntry
		if err := rows.Scan(&e.EntryID, &e.Type, &e.AmountCents, &e.BalanceAfterCents,
			&e.CreatedAt, &e.SessionID, &e.GiftID, &e.Memo); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// --- gifts ------------------------------------------------------------------

const giftCols = `gift_id, from_account_id, from_email, to_email, amount_cents, message,
 status, created_at, expires_at, accepted_at`

func scanGift(row interface{ Scan(...any) error }) (*Gift, error) {
	var g Gift
	var accepted sql.NullInt64
	err := row.Scan(&g.GiftID, &g.FromAccountID, &g.FromEmail, &g.ToEmail, &g.AmountCents,
		&g.Message, &g.Status, &g.CreatedAt, &g.ExpiresAt, &accepted)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if accepted.Valid {
		v := accepted.Int64
		g.AcceptedAt = &v
	}
	return &g, nil
}

func (d *DB) PutGift(g Gift) error {
	_, err := d.db.Exec(`INSERT INTO gifts (`+giftCols+`) VALUES (?,?,?,?,?,?,?,?,?,?)`,
		g.GiftID, g.FromAccountID, g.FromEmail, g.ToEmail, g.AmountCents, g.Message,
		g.Status, g.CreatedAt, g.ExpiresAt, g.AcceptedAt)
	return err
}

func (d *DB) Gift(id string) (*Gift, error) {
	return scanGift(d.db.QueryRow(`SELECT `+giftCols+` FROM gifts WHERE gift_id=?`, id))
}

func (d *DB) SetGiftStatus(id, status string, acceptedAt *int64) error {
	res, err := d.db.Exec(`UPDATE gifts SET status=?, accepted_at=? WHERE gift_id=? AND status=?`,
		status, acceptedAt, id, protocol.GiftPending)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrConflict
	}
	return nil
}

type GiftQuery struct {
	FromAccountID string
	ToEmail       string
	Status        string
	After         int64
	AfterID       string
	Limit         int
}

func (d *DB) ListGifts(q GiftQuery) ([]Gift, error) {
	where := []string{}
	args := []any{}
	if q.FromAccountID != "" {
		where = append(where, `from_account_id=?`)
		args = append(args, q.FromAccountID)
	}
	if q.ToEmail != "" {
		where = append(where, `to_email=?`)
		args = append(args, q.ToEmail)
	}
	if q.Status != "" {
		where = append(where, `status=?`)
		args = append(args, q.Status)
	}
	if q.After > 0 {
		where = append(where, `(created_at < ? OR (created_at = ? AND gift_id > ?))`)
		args = append(args, q.After, q.After, q.AfterID)
	}
	args = append(args, q.Limit)
	rows, err := d.db.Query(`SELECT `+giftCols+` FROM gifts WHERE `+strings.Join(where, " AND ")+
		` ORDER BY created_at DESC, gift_id ASC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Gift
	for rows.Next() {
		g, err := scanGift(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *g)
	}
	return out, rows.Err()
}

// ExpirePendingGifts refunds every gift whose hold has run out (API.md §7.3).
func (d *DB) ExpirePendingGifts(now int64) error {
	rows, err := d.db.Query(`SELECT `+giftCols+` FROM gifts WHERE status=? AND expires_at < ?`,
		protocol.GiftPending, now)
	if err != nil {
		return err
	}
	var due []Gift
	for rows.Next() {
		g, err := scanGift(rows)
		if err != nil {
			rows.Close()
			return err
		}
		due = append(due, *g)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, g := range due {
		if err := d.SetGiftStatus(g.GiftID, protocol.GiftExpired, nil); err != nil {
			return err
		}
		if _, err := d.Append(g.FromAccountID, protocol.LedgerGiftRefund, g.AmountCents, now,
			"", g.GiftID, "gift expired"); err != nil {
			return err
		}
	}
	return nil
}

// --- idempotency ------------------------------------------------------------

// BeginIdempotent claims the key. A stored record comes back for a replay; a
// claimed but unfinished record comes back with Done false.
func (d *DB) BeginIdempotent(scope, key, bodyHash string, now int64) (*Idempotent, error) {
	if _, err := d.db.Exec(`DELETE FROM idempotency WHERE scope=? AND key=? AND created_at < ?`,
		scope, key, now-int64(protocol.IdempotencyRetentionSec)*1000); err != nil {
		return nil, err
	}
	res, err := d.db.Exec(`INSERT INTO idempotency (scope, key, body_hash, created_at)
 VALUES (?,?,?,?) ON CONFLICT(scope, key) DO NOTHING`, scope, key, bodyHash, now)
	if err != nil {
		return nil, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return nil, err
	} else if n == 1 {
		return nil, nil
	}
	var rec Idempotent
	var done int
	var body []byte
	err = d.db.QueryRow(`SELECT body_hash, status, response, done FROM idempotency WHERE scope=? AND key=?`,
		scope, key).Scan(&rec.BodyHash, &rec.Status, &body, &done)
	if err != nil {
		return nil, err
	}
	rec.Done = done != 0
	rec.Response = body
	return &rec, nil
}

func (d *DB) CompleteIdempotent(scope, key string, status int, response []byte) error {
	_, err := d.db.Exec(`UPDATE idempotency SET status=?, response=?, done=1 WHERE scope=? AND key=?`,
		status, response, scope, key)
	return err
}

func (d *DB) ReleaseIdempotent(scope, key string) error {
	_, err := d.db.Exec(`DELETE FROM idempotency WHERE scope=? AND key=? AND done=0`, scope, key)
	return err
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
