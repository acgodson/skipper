// Package apidb is the rc-api SQLite store: accounts, devices, link codes,
// device tokens, session accounting, the append-only credit ledger, gifts and
// the app release table the updater reads.
// It holds no raw hardware id, no plaintext device token or link code (only their
// SHA-256), and no session content. Device-id claims live in a separate database file.
package apidb

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"rc-signal/internal/deviceid"
	"rc-signal/internal/sqlitex"
	protocol "rcprotocol"
)

var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("conflict")
	// ErrInsufficientBalance refuses a debit that would take a balance below zero.
	// Non-negativity is an invariant of the ledger, not a courtesy of its callers:
	// metering is the only debit allowed to settle for less than it asked, and it
	// says so by going through SettleCharge.
	ErrInsufficientBalance = errors.New("insufficient balance")
)

// Account.Subject is the identity provider's immutable identifier and the only
// thing an account is resolved by; Email follows it and can change. A row migrated
// from before the subject existed carries an empty one until a subject adopts it.
type Account struct {
	AccountID string
	Subject   string
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
	CodeHash  string
	NonceHash string
	Pubkey    string
	Platform  string
	Label     string
	AccountID string
	ExpiresAt int64
	Used      bool
}

type Nonce struct {
	Nonce     string
	CodeHash  string
	DeviceID  string
	ExpiresAt int64
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
	LastAliveAt        int64
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

// Idempotent.Response is the replay body; it is nil when Replayable is false,
// because that answer carried a credential that must not be stored.
type Idempotent struct {
	BodyHash     string
	Status       int
	Response     []byte
	ResponseHash string
	Replayable   bool
	Done         bool
}

type DB struct {
	db     *sql.DB
	claims *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS accounts (
  account_id     TEXT PRIMARY KEY,
  subject        TEXT NOT NULL DEFAULT '',
  email          TEXT NOT NULL,
  mailbox_key    TEXT NOT NULL DEFAULT '',
  created_at     INTEGER NOT NULL,
  suspended      INTEGER NOT NULL DEFAULT 0,
  unbilled_units INTEGER NOT NULL DEFAULT 0
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
DROP TABLE IF EXISTS link_codes;
DROP TABLE IF EXISTS nonces;
CREATE TABLE IF NOT EXISTS link_codes_v2 (
  code_hash  TEXT PRIMARY KEY,
  nonce_hash TEXT NOT NULL,
  pubkey     TEXT NOT NULL,
  platform   TEXT NOT NULL,
  label      TEXT NOT NULL DEFAULT '',
  account_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used       INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS nonces_v2 (
  nonce      TEXT PRIMARY KEY,
  code_hash  TEXT NOT NULL DEFAULT '',
  device_id  TEXT NOT NULL DEFAULT '',
  expires_at INTEGER NOT NULL,
  used       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS nonces_code ON nonces_v2(code_hash);
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
CREATE INDEX IF NOT EXISTS sessions_pair ON sessions(host_device_id, controller_device_id);
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
);
CREATE TABLE IF NOT EXISTS pending_closes (
  device_id    TEXT PRIMARY KEY,
  reason       TEXT NOT NULL,
  requested_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS releases (
  platform     TEXT NOT NULL,
  arch         TEXT NOT NULL,
  channel      TEXT NOT NULL,
  build        TEXT NOT NULL,
  version      TEXT NOT NULL,
  minimum_os   TEXT NOT NULL,
  url          TEXT NOT NULL,
  sha256       TEXT NOT NULL,
  size         INTEGER NOT NULL,
  notes        TEXT NOT NULL DEFAULT '',
  critical     INTEGER NOT NULL DEFAULT 0,
  published_at INTEGER NOT NULL,
  PRIMARY KEY (platform, arch, channel, build)
);
CREATE INDEX IF NOT EXISTS releases_latest ON releases(platform, arch, channel, published_at);`

// Open opens the API database at path and the device-id claims at claimsPath, which the
// operator keeps and backs up separately and never resets together with path (API.md §6.1).
func Open(path, claimsPath string) (*DB, error) {
	db, err := sqlitex.Open(path, schema)
	if err != nil {
		return nil, err
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	claims, err := deviceid.OpenClaims(claimsPath, db)
	if err != nil {
		db.Close()
		return nil, err
	}
	return &DB{db: db, claims: claims}, nil
}

// credentialScopes are the idempotency scopes whose stored answers once held a
// device token or link code in plaintext; migration drops those bodies.
const credentialScopes = `scope LIKE '%POST ` + protocol.PathAuthDeviceToken + `'
 OR scope LIKE '%POST ` + protocol.PathAuthDeviceRefresh + `'
 OR scope LIKE '%POST ` + protocol.PathAuthLink + `'`

func migrate(db *sql.DB) error {
	if _, err := addColumnIfMissing(db, "devices", "code_epoch", "INTEGER NOT NULL DEFAULT 1"); err != nil {
		return err
	}
	if _, err := addColumnIfMissing(db, "sessions", "last_alive_at", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if _, err := addColumnIfMissing(db, "idempotency", "response_hash", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := migrateCarryToUnbilledUnits(db); err != nil {
		return err
	}
	if err := migrateAccountsToSubjectKey(db); err != nil {
		return err
	}
	added, err := addColumnIfMissing(db, "idempotency", "replayable", "INTEGER NOT NULL DEFAULT 1")
	if err != nil || !added {
		return err
	}
	_, err = db.Exec(`UPDATE idempotency SET response=NULL, replayable=0 WHERE ` + credentialScopes)
	return err
}

// MigrateTrialsToCredit moves accounts off the calendar trial and onto starting
// credits (BETA.md §1.6), and forgives the negative balances the missing floor let
// through. Both halves are keyed on state the migration itself clears, so a restart
// runs them again and changes nothing. The grant and the window are the caller's:
// they are policy, and this only writes them.
//
// A device that held a calendar trial gets the grant it would have been given at
// link, with a fresh window: its old window was measured in days of wall clock,
// which is not convertible into hours of credit, so the hours start now.
//
// It reports how many balances it corrected and how many grants it wrote, because a
// data migration that runs silently cannot be checked afterwards.
func (d *DB) MigrateTrialsToCredit(grantCents, windowMS, now int64) (corrected, granted int, err error) {
	tx, err := d.db.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()

	debts, err := scanAccountAmounts(tx, `SELECT account_id, -SUM(amount_cents) FROM ledger
 GROUP BY account_id HAVING SUM(amount_cents) < 0`)
	if err != nil {
		return 0, 0, err
	}
	for _, a := range debts {
		if _, err := appendTx(tx, a.accountID, protocol.LedgerAdjustment, a.amount, now,
			"", "", "corrected"); err != nil {
			return 0, 0, err
		}
	}

	pending, err := scanAccountAmounts(tx, `SELECT DISTINCT d.account_id, 0 FROM devices d
 WHERE d.trial_ends_at > 0 AND d.account_id <> ''
 AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.account_id = d.account_id AND l.type = ?)`,
		protocol.LedgerTrialGrant)
	if err != nil {
		return 0, 0, err
	}
	for _, a := range pending {
		// The grant must postdate every entry already on the account, or a charge
		// written in the same millisecond would read as having consumed it. Timestamps
		// are the only order the ledger has, so the grant takes the later one.
		var latest sql.NullInt64
		if err := tx.QueryRow(`SELECT MAX(created_at) FROM ledger WHERE account_id=?`,
			a.accountID).Scan(&latest); err != nil {
			return 0, 0, err
		}
		grantedAt := max(now, latest.Int64+1)
		if _, err := appendTx(tx, a.accountID, protocol.LedgerTrialGrant, grantCents, grantedAt,
			"", "", "starting credits"); err != nil {
			return 0, 0, err
		}
		if _, err := tx.Exec(`UPDATE devices SET trial_ends_at=?
 WHERE account_id=? AND trial_ends_at > 0`, now+windowMS, a.accountID); err != nil {
			return 0, 0, err
		}
	}
	return len(debts), len(pending), tx.Commit()
}

type accountAmount struct {
	accountID string
	amount    int64
}

func scanAccountAmounts(tx *sql.Tx, query string, args ...any) ([]accountAmount, error) {
	rows, err := tx.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []accountAmount
	for rows.Next() {
		var a accountAmount
		if err := rows.Scan(&a.accountID, &a.amount); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// migrateCarryToUnbilledUnits moves the billing carry off sixtieths of a cent and
// onto units of one second at the hourly rate, which is what lets the sub-cent part
// of a session be an account allowance rather than a free window per session
// (review5 C1). Both units divide a cent — 60 of the old, 3600 of the new — so
// multiplying by 60 is exact and nobody gains or loses a fraction by it.
//
// It is keyed on the new column's absence, so a restart runs it again and changes
// nothing. The legacy column is left behind holding what it held: SQLite would have
// to rewrite the table to drop it, and nothing reads it any more.
// TODO: drop accounts.billing_carry once a table rewrite is worth scheduling.
func migrateCarryToUnbilledUnits(db *sql.DB) error {
	added, err := addColumnIfMissing(db, "accounts", "unbilled_units", "INTEGER NOT NULL DEFAULT 0")
	if err != nil || !added {
		return err
	}
	legacy, err := hasColumn(db, "accounts", "billing_carry")
	if err != nil || !legacy {
		return err
	}
	_, err = db.Exec(`UPDATE accounts SET unbilled_units = billing_carry * 60`)
	return err
}

// migrateAccountsToSubjectKey re-keys accounts on the identity provider's subject
// and demotes the email to an attribute that can change (review5 H2).
//
// It is a table rewrite because the email's uniqueness is an inline constraint, and
// that uniqueness is the defect: it is what made the address an identity. Keeping it
// would turn the day a federated provider lands from an account takeover into a hard
// refusal for every user who already signed up with the same address — better, but
// still a landmine, and the table is small enough to settle now.
//
// Existing rows keep their account_id and get an empty subject, which the first
// subject bearing their address adopts (see EnsureAccount). Keyed on the column's
// absence, so a restart runs it again and changes nothing.
func migrateAccountsToSubjectKey(db *sql.DB) error {
	present, err := hasColumn(db, "accounts", "subject")
	if err != nil {
		return err
	}
	if !present {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		for _, stmt := range []string{
			`CREATE TABLE accounts_subject_keyed (
  account_id     TEXT PRIMARY KEY,
  subject        TEXT NOT NULL DEFAULT '',
  email          TEXT NOT NULL,
  mailbox_key    TEXT NOT NULL DEFAULT '',
  created_at     INTEGER NOT NULL,
  suspended      INTEGER NOT NULL DEFAULT 0,
  unbilled_units INTEGER NOT NULL DEFAULT 0
)`,
			`INSERT INTO accounts_subject_keyed
 (account_id, subject, email, mailbox_key, created_at, suspended, unbilled_units)
 SELECT account_id, '', email, '', created_at, suspended, unbilled_units FROM accounts`,
			`DROP TABLE accounts`,
			`ALTER TABLE accounts_subject_keyed RENAME TO accounts`,
		} {
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("accounts subject migration: %w", err)
			}
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	for _, stmt := range []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS accounts_subject ON accounts(subject) WHERE subject <> ''`,
		`CREATE INDEX IF NOT EXISTS accounts_email ON accounts(email)`,
		`CREATE INDEX IF NOT EXISTS accounts_mailbox ON accounts(mailbox_key)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			return err
		}
	}
	return backfillMailboxKeys(db)
}

// backfillMailboxKeys fills the mailbox a row's address belongs to, which the trial
// grant cap counts over (review5 H4). The fold is a Go function, so this cannot be
// one UPDATE. Keyed on the empty value it writes over, so a restart is a no-op.
func backfillMailboxKeys(db *sql.DB) error {
	rows, err := db.Query(`SELECT account_id, email FROM accounts WHERE mailbox_key=''`)
	if err != nil {
		return err
	}
	keys := map[string]string{}
	for rows.Next() {
		var id, email string
		if err := rows.Scan(&id, &email); err != nil {
			rows.Close()
			return err
		}
		keys[id] = MailboxKey(email)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for id, key := range keys {
		if _, err := db.Exec(`UPDATE accounts SET mailbox_key=? WHERE account_id=?`, key, id); err != nil {
			return err
		}
	}
	return nil
}

func hasColumn(db *sql.DB, table, column string) (bool, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(1) FROM pragma_table_info(?) WHERE name=?`, table, column).Scan(&n)
	return n > 0, err
}

func addColumnIfMissing(db *sql.DB, table, column, decl string) (bool, error) {
	present, err := hasColumn(db, table, column)
	if err != nil || present {
		return false, err
	}
	_, err = db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + decl)
	return err == nil, err
}

func (d *DB) Close() error { return errors.Join(d.db.Close(), d.claims.Close()) }

func NewID(prefix string) string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(b)
}

func NormaliseEmail(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

// MailboxKey folds an address to the mailbox behind it by dropping a plus tag, so
// one mailbox is worth one trial grant however many addresses it yields
// (review5 H4). It is used only to decide whether a *free grant* is due: it never
// merges accounts, never resolves an identity and never denies anyone service, so
// the cost of folding two genuinely distinct addresses together is 50 cents of
// credit, not access. Dots are left alone: they are a provider-specific convention
// and treating them as insignificant would be wrong on most domains.
func MailboxKey(email string) string {
	email = NormaliseEmail(email)
	at := strings.LastIndex(email, "@")
	if at < 0 {
		return email
	}
	local, domain := email[:at], email[at:]
	if plus := strings.Index(local, "+"); plus >= 0 {
		local = local[:plus]
	}
	return local + domain
}

// --- accounts ---------------------------------------------------------------

const accountCols = `account_id, subject, email, created_at, suspended`

func scanAccount(row interface{ Scan(...any) error }) (*Account, error) {
	var a Account
	var suspended int
	err := row.Scan(&a.AccountID, &a.Subject, &a.Email, &a.CreatedAt, &suspended)
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

func (d *DB) AccountBySubject(subject string) (*Account, error) {
	return scanAccount(d.db.QueryRow(`SELECT `+accountCols+` FROM accounts WHERE subject=? AND subject<>''`, subject))
}

// EnsureAccount resolves the account an identity provider just vouched for, keyed on
// the provider's immutable subject. The email is a display attribute: it follows the
// subject rather than identifying it, so a user who changes address keeps their
// account and a second identity carrying someone else's address gets its own
// (review5 H2).
//
// An account predating the subject column is adopted by the first subject that
// arrives bearing its address. That is the migration for the accounts that exist:
// idempotent, because it only ever fills an empty subject, and sound on the live
// pool, where email is the username and no federated provider exists, so two
// subjects cannot carry one address. The window closes the first time the owner
// signs in. A row whose subject is already set is never re-keyed by an address.
func (d *DB) EnsureAccount(subject, email string, now time.Time) (*Account, error) {
	if subject == "" {
		return nil, fmt.Errorf("apidb: an account needs an identity provider subject")
	}
	email = NormaliseEmail(email)
	tx, err := d.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var accountID, heldSubject, heldEmail string
	err = tx.QueryRow(`SELECT account_id, subject, email FROM accounts
 WHERE subject=? OR (subject='' AND email=?)`, subject, email).Scan(&accountID, &heldSubject, &heldEmail)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		accountID = NewID("acct_")
		if _, err := tx.Exec(`INSERT INTO accounts
 (account_id, subject, email, mailbox_key, created_at, suspended) VALUES (?,?,?,?,?,0)`,
			accountID, subject, email, MailboxKey(email), now.UnixMilli()); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	case heldSubject == "" || heldEmail != email:
		if _, err := tx.Exec(`UPDATE accounts SET subject=?, email=?, mailbox_key=? WHERE account_id=?`,
			subject, email, MailboxKey(email), accountID); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
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

// RegisterDevice is idempotent by pubkey; certifiedID is an id a verified
// device-id certificate binds to this pubkey, or "" (see deviceid.Assign).
// A restore that displaces another key drops that key's record and revokes its tokens.
func (d *DB) RegisterDevice(dev Device, certifiedID string) (*Device, deviceid.Result, error) {
	if dev.Pubkey == "" {
		return nil, deviceid.Result{}, errors.New("a device needs a public key")
	}
	ledger := deviceid.SQL{
		DB: d.db, Claims: d.claims,
		Insert: func(tx *sql.Tx, id string) error {
			_, err := tx.Exec(`INSERT INTO devices
 (device_id, account_id, label, platform, pubkey, hardware_hash, created_at, linked_at, last_seen, trial_ends_at, unlinked)
 VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
				id, dev.AccountID, dev.Label, dev.Platform, dev.Pubkey, dev.HardwareHash,
				dev.CreatedAt, dev.LinkedAt, dev.LastSeen, dev.TrialEndsAt, boolInt(dev.Unlinked))
			return err
		},
		Evict: func(tx *sql.Tx, id string) error {
			if _, err := tx.Exec(`UPDATE device_tokens SET revoked=1 WHERE device_id=?`, id); err != nil {
				return err
			}
			_, err := tx.Exec(`DELETE FROM devices WHERE device_id=?`, id)
			return err
		},
	}
	result, err := deviceid.Assign(ledger, dev.Pubkey, certifiedID)
	if err != nil {
		return nil, result, err
	}
	found, err := d.DeviceByID(result.ID)
	return found, result, err
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
	_, err := d.db.Exec(`INSERT INTO link_codes_v2 (code_hash, nonce_hash, pubkey, platform, label, account_id, expires_at, used)
 VALUES (?,?,?,?,?,?,?,0)`, c.CodeHash, c.NonceHash, c.Pubkey, c.Platform, c.Label, c.AccountID, c.ExpiresAt)
	return err
}

func (d *DB) LinkCodeByHash(codeHash string) (*LinkCode, error) {
	var c LinkCode
	var used int
	err := d.db.QueryRow(`SELECT code_hash, nonce_hash, pubkey, platform, label, account_id, expires_at, used
 FROM link_codes_v2 WHERE code_hash=?`, codeHash).
		Scan(&c.CodeHash, &c.NonceHash, &c.Pubkey, &c.Platform, &c.Label, &c.AccountID, &c.ExpiresAt, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	c.Used = used != 0
	return &c, nil
}

func (d *DB) UseLinkCode(codeHash string) error {
	res, err := d.db.Exec(`UPDATE link_codes_v2 SET used=1 WHERE code_hash=? AND used=0`, codeHash)
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
	_, err := d.db.Exec(`INSERT INTO nonces_v2 (nonce, code_hash, device_id, expires_at, used) VALUES (?,?,?,?,0)`,
		n.Nonce, n.CodeHash, n.DeviceID, n.ExpiresAt)
	return err
}

func (d *DB) consumeOne(query string, args ...any) (string, error) {
	var nonce string
	err := d.db.QueryRow(query, args...).Scan(&nonce)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return nonce, err
}

// ConsumeDeviceNonce spends exactly the nonce issued for deviceID, in one
// statement; a replay, an expired nonce or another device's nonce is ErrNotFound.
func (d *DB) ConsumeDeviceNonce(nonce, deviceID string, now int64) error {
	_, err := d.consumeOne(`UPDATE nonces_v2 SET used=1
 WHERE nonce=? AND device_id=? AND device_id<>'' AND used=0 AND expires_at>=? RETURNING nonce`,
		nonce, deviceID, now)
	return err
}

// ConsumeCodeNonce spends the newest live nonce issued for a link code, in one statement.
func (d *DB) ConsumeCodeNonce(codeHash string, now int64) (string, error) {
	return d.consumeOne(`UPDATE nonces_v2 SET used=1 WHERE used=0 AND nonce=(
 SELECT nonce FROM nonces_v2 WHERE code_hash=? AND code_hash<>'' AND used=0 AND expires_at>=?
 ORDER BY expires_at DESC LIMIT 1) RETURNING nonce`, codeHash, now)
}

func (d *DB) PurgeExpired(now int64) error {
	for _, q := range []string{
		`DELETE FROM nonces_v2 WHERE expires_at < ?`,
		`DELETE FROM link_codes_v2 WHERE expires_at < ?`,
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
 started_at, ended_at, relay_used, bytes_relayed, reason, last_alive_at`

func scanSession(row interface{ Scan(...any) error }) (*Session, error) {
	var s Session
	var relay int
	var ended, bytes sql.NullInt64
	err := row.Scan(&s.SessionID, &s.HostDeviceID, &s.ControllerDeviceID, &s.HostAccountID,
		&s.StartedAt, &ended, &relay, &bytes, &s.Reason, &s.LastAliveAt)
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
 (session_id, host_device_id, controller_device_id, host_account_id, started_at, relay_used, reason, last_alive_at)
 VALUES (?,?,?,?,?,0,'',?) ON CONFLICT(session_id) DO NOTHING`,
		s.SessionID, s.HostDeviceID, s.ControllerDeviceID, s.HostAccountID, s.StartedAt, s.StartedAt)
	return err
}

// OpenSessions lists every session that has no end yet.
func (d *DB) OpenSessions() ([]Session, error) {
	rows, err := d.db.Query(`SELECT ` + sessionCols + ` FROM sessions WHERE ended_at IS NULL`)
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

// MarkAlive records that signaling still held the session at the given time.
func (d *DB) MarkAlive(sessionID string, at int64) error {
	_, err := d.db.Exec(`UPDATE sessions SET last_alive_at=MAX(last_alive_at, ?)
 WHERE session_id=? AND ended_at IS NULL`, at, sessionID)
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

// --- pending session closes -------------------------------------------------

// PendingClose is an unlink whose live sessions signaling did not confirm closed.
type PendingClose struct {
	DeviceID    string
	Reason      string
	RequestedAt int64
}

func (d *DB) AddPendingClose(deviceID, reason string, at int64) error {
	_, err := d.db.Exec(`INSERT INTO pending_closes (device_id, reason, requested_at) VALUES (?,?,?)
 ON CONFLICT(device_id) DO UPDATE SET reason=excluded.reason`, deviceID, reason, at)
	return err
}

func (d *DB) PendingCloses() ([]PendingClose, error) {
	rows, err := d.db.Query(`SELECT device_id, reason, requested_at FROM pending_closes ORDER BY requested_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingClose
	for rows.Next() {
		var p PendingClose
		if err := rows.Scan(&p.DeviceID, &p.Reason, &p.RequestedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (d *DB) ClearPendingClose(deviceID string) error {
	_, err := d.db.Exec(`DELETE FROM pending_closes WHERE device_id=?`, deviceID)
	return err
}

// PairKnown reports whether the controller has had a metered session with the host.
func (d *DB) PairKnown(hostDeviceID, controllerDeviceID string) (bool, error) {
	return d.exists(`SELECT COUNT(1) FROM (SELECT 1 FROM sessions WHERE host_device_id=? AND controller_device_id=? LIMIT 1)`,
		hostDeviceID, controllerDeviceID)
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
// A debit larger than the balance is ErrInsufficientBalance: no entry may take an
// account below zero.
func (d *DB) Append(accountID, entryType string, amountCents int64, now int64, sessionID, giftID, memo string) (protocol.LedgerEntry, error) {
	tx, err := d.db.Begin()
	if err != nil {
		return protocol.LedgerEntry{}, err
	}
	defer tx.Rollback()
	entry, err := appendTx(tx, accountID, entryType, amountCents, now, sessionID, giftID, memo)
	if err != nil {
		return protocol.LedgerEntry{}, err
	}
	return entry, tx.Commit()
}

func balanceTx(tx *sql.Tx, accountID string) (int64, error) {
	var sum sql.NullInt64
	err := tx.QueryRow(`SELECT SUM(amount_cents) FROM ledger WHERE account_id=?`, accountID).Scan(&sum)
	return sum.Int64, err
}

func appendTx(tx *sql.Tx, accountID, entryType string, amountCents, now int64,
	sessionID, giftID, memo string) (protocol.LedgerEntry, error) {
	balance, err := balanceTx(tx, accountID)
	if err != nil {
		return protocol.LedgerEntry{}, err
	}
	if balance+amountCents < 0 {
		return protocol.LedgerEntry{}, ErrInsufficientBalance
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
	_, err = tx.Exec(`INSERT INTO ledger
 (entry_id, account_id, type, amount_cents, balance_after_cents, created_at, session_id, gift_id, memo)
 VALUES (?,?,?,?,?,?,?,?,?)`, entry.EntryID, accountID, entry.Type, entry.AmountCents,
		entry.BalanceAfterCents, entry.CreatedAt, entry.SessionID, entry.GiftID, entry.Memo)
	return entry, err
}

// Charge is what SettleCharge asks the policy for: the cost of the session in whole
// cents given the carry the account is holding, and the carry it leaves behind.
type Charge func(carry int64) (cents, newCarry int64)

// Settlement is what one session cost once the balance had its say.
type Settlement struct {
	Entry   protocol.LedgerEntry
	Billed  bool
	Clamped bool
}

// SettleCharge prices one session against the account's carry and its balance, in a
// single transaction so a concurrent top-up or charge can neither be lost nor
// double-spent.
//
// A charge larger than the balance is clamped to the balance rather than refused:
// the session already happened, the floor still holds, and Clamped tells the caller
// the account has run out so the session can be closed. A clamped charge drops the
// carry as well, so the shortfall is never carried forward onto a later top-up.
func (d *DB) SettleCharge(accountID, sessionID string, now int64, price Charge) (Settlement, error) {
	tx, err := d.db.Begin()
	if err != nil {
		return Settlement{}, err
	}
	defer tx.Rollback()
	var carry int64
	if err := tx.QueryRow(`SELECT unbilled_units FROM accounts WHERE account_id=?`,
		accountID).Scan(&carry); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Settlement{}, ErrNotFound
		}
		return Settlement{}, err
	}
	balance, err := balanceTx(tx, accountID)
	if err != nil {
		return Settlement{}, err
	}
	cents, newCarry := price(carry)
	out := Settlement{}
	if cents > balance {
		cents, newCarry = max(balance, 0), 0
		out.Clamped = true
	}
	if cents > 0 {
		entry, err := appendTx(tx, accountID, protocol.LedgerSessionCharge, -cents, now,
			sessionID, "", "session time")
		if err != nil {
			return Settlement{}, err
		}
		out.Entry, out.Billed = entry, true
	}
	if _, err := tx.Exec(`UPDATE accounts SET unbilled_units=? WHERE account_id=?`,
		newCarry, accountID); err != nil {
		return Settlement{}, err
	}
	return out, tx.Commit()
}

// UnconsumedGrant reports the part of the account's starting credits that no session
// has spent, and whether a grant window is still open at all.
//
// Charges consume the grant before paid credit, so every session charge since the
// grant counts against it. What tells grant apart from paid credit is the entry type:
// the claw-back is a trial_expiry rather than a plain adjustment, so an operator
// correction can never read as consumed or expired grant. A trial_expiry closes the
// window whatever it was worth — a window that expired with nothing left to take is
// still closed — and only a grant written after it opens a new one.
func (d *DB) UnconsumedGrant(accountID string) (cents int64, open bool, err error) {
	var lastExpiry, firstGrant sql.NullInt64
	if err := d.db.QueryRow(`SELECT MAX(created_at) FROM ledger
 WHERE account_id=? AND type=?`, accountID, protocol.LedgerTrialExpiry).Scan(&lastExpiry); err != nil {
		return 0, false, err
	}
	if err := d.db.QueryRow(`SELECT MIN(created_at) FROM ledger
 WHERE account_id=? AND type=? AND created_at > ?`,
		accountID, protocol.LedgerTrialGrant, lastExpiry.Int64).Scan(&firstGrant); err != nil {
		return 0, false, err
	}
	if !firstGrant.Valid {
		return 0, false, nil
	}
	var granted, charged sql.NullInt64
	err = d.db.QueryRow(`SELECT
 SUM(CASE WHEN type=? AND created_at >= ? THEN amount_cents END),
 SUM(CASE WHEN type=? AND created_at >= ? THEN -amount_cents END)
 FROM ledger WHERE account_id=?`,
		protocol.LedgerTrialGrant, firstGrant.Int64,
		protocol.LedgerSessionCharge, firstGrant.Int64, accountID).Scan(&granted, &charged)
	if err != nil {
		return 0, false, err
	}
	return max(0, granted.Int64-charged.Int64), true, nil
}

// HeldPaidCredit answers whether credit the account did not get for free has ever
// landed on it: any incoming entry that is not a trial_grant, so a top-up, a received
// gift, a refund or an operator credit all count and the grant never does.
//
// It is history, not balance. Once an account has been paid for it is a paying account
// for ever, which is what makes it the fact that decides whether a balance of zero is
// that account's trial ending or its own credit running out (policy.Decide).
func (d *DB) HeldPaidCredit(accountID string) (bool, error) {
	var held bool
	err := d.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM ledger
 WHERE account_id=? AND type<>? AND amount_cents>0)`,
		accountID, protocol.LedgerTrialGrant).Scan(&held)
	return held, err
}

// TrialGrantsForMailbox counts the grants already written to every account whose
// address folds to the same mailbox as this account's. The count is server-side
// fact, which is what makes it a bound where the device inputs are not (review5 H4).
//
// An account that does not exist is ErrNotFound rather than a count of zero: the
// caller is deciding whether to give away credit, and "I could not tell" must not
// read as "none yet".
func (d *DB) TrialGrantsForMailbox(accountID string) (int, error) {
	var key string
	if err := d.db.QueryRow(`SELECT mailbox_key FROM accounts WHERE account_id=?`,
		accountID).Scan(&key); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotFound
		}
		return 0, err
	}
	var n int
	err := d.db.QueryRow(`SELECT COUNT(1) FROM ledger l JOIN accounts a
 ON a.account_id = l.account_id
 WHERE l.type=? AND a.mailbox_key=?`, protocol.LedgerTrialGrant, key).Scan(&n)
	return n, err
}

// TrialWindowForAccount is when the account's starting credits expire: the latest
// window any of its linked devices holds, 0 if none does.
//
// The grant is one per account, so the window has to be read per account too. Read
// off the calling device alone, a second device on the account reported no window
// while spending the account's starting credits, which made it read `active` where
// API.md §4.1 says `trial`.
func (d *DB) TrialWindowForAccount(accountID string) (int64, error) {
	var at sql.NullInt64
	err := d.db.QueryRow(`SELECT MAX(trial_ends_at) FROM devices
 WHERE account_id=? AND unlinked=0`, accountID).Scan(&at)
	return at.Int64, err
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

// CreateGift holds a gift: it writes the pending row and the debit that pays for it
// in one transaction, so a refused debit leaves nothing behind.
//
// Written separately, a debit the ledger refused left an unpaid pending gift that
// became real credit two ways — the recipient accepting it, or nobody doing anything
// and the expiry refunding it to a sender who never paid (review5 H3). There is no
// balance check here either: the ledger's own invariant is the check, and a read
// before the transaction can only be stale.
func (d *DB) CreateGift(g Gift, memo string) (Gift, error) {
	tx, err := d.db.Begin()
	if err != nil {
		return Gift{}, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO gifts (`+giftCols+`) VALUES (?,?,?,?,?,?,?,?,?,?)`,
		g.GiftID, g.FromAccountID, g.FromEmail, g.ToEmail, g.AmountCents, g.Message,
		g.Status, g.CreatedAt, g.ExpiresAt, g.AcceptedAt); err != nil {
		return Gift{}, err
	}
	if _, err := appendTx(tx, g.FromAccountID, protocol.LedgerGiftSent, -g.AmountCents,
		g.CreatedAt, "", g.GiftID, memo); err != nil {
		return Gift{}, err
	}
	return g, tx.Commit()
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
		// A refund that is not the reverse of a debit is not a refund. CreateGift
		// makes an unpaid pending row impossible, so this cannot fire; it stays
		// because being wrong here mints credit from nothing (review5 H3).
		paid, err := d.giftWasPaidFor(g.GiftID)
		if err != nil {
			return err
		}
		if err := d.SetGiftStatus(g.GiftID, protocol.GiftExpired, nil); err != nil {
			return err
		}
		if !paid {
			continue
		}
		if _, err := d.Append(g.FromAccountID, protocol.LedgerGiftRefund, g.AmountCents, now,
			"", g.GiftID, "gift expired"); err != nil {
			return err
		}
	}
	return nil
}

func (d *DB) giftWasPaidFor(giftID string) (bool, error) {
	return d.exists(`SELECT COUNT(1) FROM ledger WHERE gift_id=? AND type=?`,
		giftID, protocol.LedgerGiftSent)
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
	var done, replayable int
	var body []byte
	err = d.db.QueryRow(`SELECT body_hash, status, response, response_hash, replayable, done
 FROM idempotency WHERE scope=? AND key=?`,
		scope, key).Scan(&rec.BodyHash, &rec.Status, &body, &rec.ResponseHash, &replayable, &done)
	if err != nil {
		return nil, err
	}
	rec.Done = done != 0
	rec.Replayable = replayable != 0
	if rec.Replayable {
		rec.Response = body
	}
	return &rec, nil
}

// CompleteIdempotent stores the answer's hash always and its body only when replayable.
func (d *DB) CompleteIdempotent(scope, key string, status int, response []byte, replayable bool) error {
	sum := sha256.Sum256(response)
	var body []byte
	if replayable {
		body = response
	}
	_, err := d.db.Exec(`UPDATE idempotency SET status=?, response=?, response_hash=?, replayable=?, done=1
 WHERE scope=? AND key=?`,
		status, body, hex.EncodeToString(sum[:]), boolInt(replayable), scope, key)
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
