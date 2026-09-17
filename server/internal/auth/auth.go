// Package auth holds every cryptographic primitive the signaling server needs:
// device-key challenge/response, HMAC session tokens and coturn REST-auth credential minting.
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

	"rcprotocol"
)

var (
	ErrBadSignature = errors.New("signature verification failed")
	ErrBadToken     = errors.New("session token invalid")
)

func NewNonce() ([]byte, string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, "", err
	}
	return b, base64.StdEncoding.EncodeToString(b), nil
}

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

// VerifyDeviceSig checks a device-key signature over
// protocol.SigningMessage(purpose, nonce). The nonce must be exactly
// protocol.NonceLen bytes, so a signature made for one purpose never
// authenticates another.
func VerifyDeviceSig(purpose protocol.SigningPurpose, pubkeyB64, sigB64 string, nonce []byte) error {
	if purpose == protocol.PurposeSDP {
		return ErrBadSignature
	}
	message, err := protocol.SigningMessage(purpose, nonce)
	if err != nil {
		return ErrBadSignature
	}
	pub, err := ParsePubkey(pubkeyB64)
	if err != nil {
		return ErrBadSignature
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return ErrBadSignature
	}
	sum := sha256.Sum256(message)
	if !ecdsa.VerifyASN1(pub, sum[:], sig) {
		return ErrBadSignature
	}
	return nil
}

type TokenClaims struct {
	SessionID string
	DeviceID  string
	Expiry    time.Time
	Epoch     int64
	Nonce     string
}

type Signer struct {
	secret []byte
}

func NewSigner(secret []byte) *Signer {
	cp := make([]byte, len(secret))
	copy(cp, secret)
	return &Signer{secret: cp}
}

func NewRandomSigner() (*Signer, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return NewSigner(b), nil
}

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

func (s *Signer) Mint(c TokenClaims) string {
	body := strings.Join([]string{
		c.SessionID, c.DeviceID, strconv.FormatInt(c.Expiry.Unix(), 10),
		strconv.FormatInt(c.Epoch, 10), c.Nonce,
	}, ":")
	enc := base64.RawURLEncoding.EncodeToString([]byte(body))
	return enc + "." + s.mac(body)
}

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

func TurnCreds(secret, deviceID string, now time.Time, ttl time.Duration) (username, credential string, expiresAt time.Time) {
	expiresAt = now.Add(ttl)
	username = strconv.FormatInt(expiresAt.Unix(), 10) + ":" + deviceID
	m := hmac.New(sha1.New, []byte(secret))
	m.Write([]byte(username))
	credential = base64.StdEncoding.EncodeToString(m.Sum(nil))
	return username, credential, expiresAt
}
