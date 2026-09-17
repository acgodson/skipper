// Package idcert is the registry's device-ID certificate authority: a P-256 key
// held by the server that vouches "this deviceId belongs to this device key".
// A certificate survives a registry reset, so it is what lets a device reclaim its id.
package idcert

import (
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

// TODO: move the signing key to AWS KMS in Phase 5; the file is the local stand-in.

type Authority struct {
	key *ecdsa.PrivateKey
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
	return &Authority{key: key}, nil
}

// Ephemeral makes a throwaway authority; certificates die with the process.
func Ephemeral() (*Authority, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Authority{key: key}, nil
}

// Open loads path, or in insecure local mode with no path makes an ephemeral authority.
func Open(path string, insecure bool) (*Authority, bool, error) {
	if path != "" {
		a, err := Load(path)
		return a, false, err
	}
	if !insecure {
		return nil, false, errors.New("a device-id certificate key file is required unless running insecure local HTTP")
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
func (a *Authority) Issue(deviceID, pubkeyB64 string) (string, error) {
	sum, err := digest(deviceID, pubkeyB64)
	if err != nil {
		return "", err
	}
	sig, err := ecdsa.SignASN1(rand.Reader, a.key, sum)
	if err != nil {
		return "", err
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
	return ecdsa.VerifyASN1(&a.key.PublicKey, sum, sig)
}
