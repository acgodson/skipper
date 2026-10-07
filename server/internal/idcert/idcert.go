// Package idcert is the registry's device-ID certificate authority: a P-256 key
// held by the server that vouches "this deviceId belongs to this device key".
// A certificate survives a registry reset, so it is what lets a device reclaim its id.
package idcert

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"os"

	"rc-signal/internal/auth"
	protocol "rcprotocol"
)

// signer owns the private half and nothing else. The file and KMS paths differ only
// here: everything that decides the bytes on the wire stays in Authority, so a
// certificate signed either way is byte-for-byte the same shape.
type signer interface {
	signDigest(ctx context.Context, digest []byte) ([]byte, error)
}

type Authority struct {
	pub    *ecdsa.PublicKey
	signer signer
}

type localKey struct {
	key *ecdsa.PrivateKey
}

func (l localKey) signDigest(_ context.Context, digest []byte) ([]byte, error) {
	return ecdsa.SignASN1(rand.Reader, l.key, digest)
}

func fromPrivateKey(key *ecdsa.PrivateKey) *Authority {
	return &Authority{pub: &key.PublicKey, signer: localKey{key: key}}
}

// Load reads a PEM "PRIVATE KEY" (PKCS#8) holding a P-256 key.
func Load(path string) (*Authority, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("device-id certificate key: %w", err)
	}
	block, _ := pem.Decode(raw)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, errors.New("device-id certificate key: want a PEM PKCS#8 PRIVATE KEY block")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("device-id certificate key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("device-id certificate key: want a P-256 key")
	}
	return fromPrivateKey(key), nil
}

// Ephemeral makes a throwaway authority; certificates die with the process.
func Ephemeral() (*Authority, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return fromPrivateKey(key), nil
}

// Config says where the signing key lives. KMSKeyID is the only option whose private
// half never exists in this process; KeyFile is the local stand-in and they are
// mutually exclusive.
type Config struct {
	KeyFile  string
	KMSKeyID string
	Insecure bool
}

// Open resolves cfg to an authority, reporting whether the key is a throwaway one.
func Open(ctx context.Context, cfg Config) (*Authority, bool, error) {
	if cfg.KeyFile != "" && cfg.KMSKeyID != "" {
		return nil, false, errors.New("-id-cert-key-file and -id-cert-kms-key-id are mutually exclusive: pass only -id-cert-kms-key-id to keep the private key inside KMS")
	}
	if cfg.KMSKeyID != "" {
		a, err := openKMS(ctx, cfg.KMSKeyID)
		return a, false, err
	}
	if cfg.KeyFile != "" {
		a, err := Load(cfg.KeyFile)
		return a, false, err
	}
	if !cfg.Insecure {
		return nil, false, errors.New("a device-id certificate key is required unless running insecure local HTTP: pass -id-cert-kms-key-id or -id-cert-key-file")
	}
	a, err := Ephemeral()
	return a, true, err
}

func digest(deviceID, pubkeyB64 string) ([]byte, error) {
	if _, err := auth.ParsePubkey(pubkeyB64); err != nil {
		return nil, err
	}
	der, err := base64.StdEncoding.DecodeString(pubkeyB64)
	if err != nil {
		return nil, err
	}
	message, err := protocol.DeviceIDCertMessage(deviceID, der)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(message)
	return sum[:], nil
}

// Issue returns the base64 DER ECDSA signature binding deviceID to pubkeyB64.
// A KMS-backed authority makes a network call here, so a failure means no certificate
// rather than a wrong one: the caller must treat the error as the registration failing.
func (a *Authority) Issue(ctx context.Context, deviceID, pubkeyB64 string) (string, error) {
	sum, err := digest(deviceID, pubkeyB64)
	if err != nil {
		return "", err
	}
	sig, err := a.signer.signDigest(ctx, sum)
	if err != nil {
		return "", err
	}
	if len(sig) == 0 {
		return "", errors.New("device-id certificate: the signer returned no signature")
	}
	return base64.StdEncoding.EncodeToString(sig), nil
}

// CertifiedID returns preferred when cert certifies it for pubkeyB64, else "".
func (a *Authority) CertifiedID(pubkeyB64, preferred, cert string) string {
	if preferred != "" && a.Verify(preferred, pubkeyB64, cert) {
		return preferred
	}
	return ""
}

// Verify reports whether cert is this authority's certificate for (deviceID, pubkeyB64).
func (a *Authority) Verify(deviceID, pubkeyB64, cert string) bool {
	if cert == "" {
		return false
	}
	sig, err := base64.StdEncoding.DecodeString(cert)
	if err != nil {
		return false
	}
	sum, err := digest(deviceID, pubkeyB64)
	if err != nil {
		return false
	}
	return ecdsa.VerifyASN1(a.pub, sum, sig)
}
