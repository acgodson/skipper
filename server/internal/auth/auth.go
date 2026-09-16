// Package auth holds every cryptographic primitive the signaling server needs:
// device-key challenge/response, HMAC session tokens and coturn REST-auth
// credential minting.
//
// Under protocol v2 there is deliberately no access-code primitive here: the
// code is proved peer to peer (PROTOCOL.md §2.17) and the server never sees it.
//
// Nothing in this package logs. Callers must never log its inputs either:
// session tokens are secrets.
package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Errors returned by this package. Callers map them onto protocol error codes.
var (
	ErrBadSignature = errors.New("signature verification failed")
	ErrBadToken     = errors.New("session token invalid")
)

// ---------------------------------------------------------------------------
// Device identity
// ---------------------------------------------------------------------------

// NewNonce returns 32 random bytes and their base64 encoding.
func NewNonce() ([]byte, string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, "", err
	}
	return b, base64.StdEncoding.EncodeToString(b), nil
}

// ParsePubkey decodes a base64 DER SPKI P-256 public key.
func ParsePubkey(b64 string) (*ecdsa.PublicKey, error) {
	der, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("pubkey is not base64: %w", err)
	}
	pk, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, fmt.Errorf("pubkey is not a DER SPKI key: %w", err)
	}
	pub, ok := pk.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("pubkey is not an ECDSA key")
	}
	if pub.Curve != elliptic.P256() {
		return nil, errors.New("pubkey is not on P-256")
	}
	return pub, nil
}

// VerifyDeviceSig checks a base64 ASN.1-DER ECDSA-SHA256 signature over the raw
// nonce bytes. Any failure returns ErrBadSignature; the reason is deliberately
// not distinguished to the caller's clients.
func VerifyDeviceSig(pubkeyB64, sigB64 string, nonce []byte) error {
	pub, err := ParsePubkey(pubkeyB64)
	if err != nil {
		return ErrBadSignature
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return ErrBadSignature
	}
	sum := sha256.Sum256(nonce)
	if !ecdsa.VerifyASN1(pub, sum[:], sig) {
		return ErrBadSignature
	}
	return nil
}

// ---------------------------------------------------------------------------
// Session tokens
// ---------------------------------------------------------------------------

// TokenClaims are the fields carried inside a session token.
type TokenClaims struct {
	SessionID string
	DeviceID  string
	Expiry    time.Time
	Epoch     int64  // device code epoch; a refresh bumps it and kills old tokens
	Nonce     string // rotated on every issue, so a used token cannot be replayed
}

// Signer mints and verifies session tokens with HMAC-SHA256.
type Signer struct {
	secret []byte
}

// NewSigner returns a Signer over the given secret. The secret must have at
// least 128 bits of entropy in production.
func NewSigner(secret []byte) *Signer {
	cp := make([]byte, len(secret))
	copy(cp, secret)
	return &Signer{secret: cp}
}

// NewRandomSigner returns a Signer with a fresh 32-byte random secret. Tokens
// minted by it do not survive a server restart, which is acceptable: a restart
// drops all in-memory sessions anyway.
func NewRandomSigner() (*Signer, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return NewSigner(b), nil
}

// NewTokenNonce returns a fresh random token nonce (base64url, 16 bytes).
func NewTokenNonce() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func (s *Signer) mac(body string) string {
	m := hmac.New(sha256.New, s.secret)
	m.Write([]byte(body))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// Mint returns "base64url(body).base64url(mac)".
func (s *Signer) Mint(c TokenClaims) string {
	body := strings.Join([]string{
		c.SessionID, c.DeviceID, strconv.FormatInt(c.Expiry.Unix(), 10),
		strconv.FormatInt(c.Epoch, 10), c.Nonce,
	}, ":")
	enc := base64.RawURLEncoding.EncodeToString([]byte(body))
	return enc + "." + s.mac(body)
}

// Parse verifies the MAC and returns the claims. It does NOT check expiry,
// session liveness, epoch currency or nonce freshness — the hub does, because
// only the hub knows the current session state.
func (s *Signer) Parse(token string) (TokenClaims, error) {
	enc, mac, ok := strings.Cut(token, ".")
	if !ok {
		return TokenClaims{}, ErrBadToken
	}
	bodyB, err := base64.RawURLEncoding.DecodeString(enc)
	if err != nil {
		return TokenClaims{}, ErrBadToken
	}
	body := string(bodyB)
	if subtle.ConstantTimeCompare([]byte(mac), []byte(s.mac(body))) != 1 {
		return TokenClaims{}, ErrBadToken
	}
	parts := strings.Split(body, ":")
	if len(parts) != 5 {
		return TokenClaims{}, ErrBadToken
	}
	exp, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return TokenClaims{}, ErrBadToken
	}
	epoch, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		return TokenClaims{}, ErrBadToken
	}
	return TokenClaims{
		SessionID: parts[0], DeviceID: parts[1],
		Expiry: time.Unix(exp, 0), Epoch: epoch, Nonce: parts[4],
	}, nil
}

// ---------------------------------------------------------------------------
// TURN credentials (coturn use-auth-secret / REST auth)
// ---------------------------------------------------------------------------

// TurnCreds mints an ephemeral coturn credential pair:
//
//	username   = "<unixExpiry>:<deviceId>"
//	credential = base64(HMAC-SHA1(username, secret))
func TurnCreds(secret, deviceID string, now time.Time, ttl time.Duration) (username, credential string, expiresAt time.Time) {
	expiresAt = now.Add(ttl)
	username = strconv.FormatInt(expiresAt.Unix(), 10) + ":" + deviceID
	m := hmac.New(sha1.New, []byte(secret))
	m.Write([]byte(username))
	credential = base64.StdEncoding.EncodeToString(m.Sum(nil))
	return username, credential, expiresAt
}
