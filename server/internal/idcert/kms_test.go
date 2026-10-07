package idcert

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"math/big"
	"testing"
	"time"
)

// A certificate captured from the file signer, kept as literal bytes so the encoding on
// the wire is pinned independently of whatever signs it. kms:Sign with ECDSA_SHA_256
// returns this same ASN.1 DER encoding, which is why the KMS path needs no conversion:
// a fixed-width r‖s pair would be exactly 64 bytes and carry no SEQUENCE tag.
const (
	vectorAuthoritySPKIHex = "3059301306072a8648ce3d020106082a8648ce3d03010703420004bd0c736c39353a52643c1cf68fa8cb1ade58dfed1a00d2cff6822dd4690e18055fce1fbfa1acfcbc3fc90b28295f65480c45c8d9393ebc2683c453d7c5d028c1"
	vectorDevicePubkeyB64  = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEsb4Q6K0cEyXKuxeGtZd5euar+JsWcv8j1Xo9gyfixvfC88S7seQCTvUKvLVX+A8/amSYD2l32nF/ChTcbpqwXA=="
	vectorDeviceID         = "481930275"
	vectorCertB64          = "MEQCIFM9IDDiBg1zFPrq3eN8UpGDCVUYT6zQsjw9Hc4IIk4PAiAlyjJaDy3Xc6zkvBYNWntpbLrS6jp1TZE8VLhSeYQIzg=="
)

func vectorAuthority(t *testing.T) *Authority {
	t.Helper()
	der, err := hex.DecodeString(vectorAuthoritySPKIHex)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := parseKMSPublicKey(der)
	if err != nil {
		t.Fatal(err)
	}
	return &Authority{pub: pub}
}

// This is the proof that moving the private half into KMS changes no byte on the wire:
// the certificate is ASN.1 DER, the public key arrives as the DER SPKI kms:GetPublicKey
// returns, and the existing verifier accepts the pair.
func TestTheWireFormatIsDERAndNotAFixedWidthPair(t *testing.T) {
	a := vectorAuthority(t)
	if !a.Verify(vectorDeviceID, vectorDevicePubkeyB64, vectorCertB64) {
		t.Fatal("the pinned certificate no longer verifies: the signed message or the encoding changed")
	}

	sig, err := base64.StdEncoding.DecodeString(vectorCertB64)
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) == 64 {
		t.Fatal("the certificate is a 64-byte fixed-width r‖s pair, not the DER the contract specifies")
	}
	var parsed struct{ R, S *big.Int }
	rest, err := asn1.Unmarshal(sig, &parsed)
	if err != nil || len(rest) != 0 {
		t.Fatalf("the certificate is not a DER SEQUENCE of two INTEGERs: err=%v trailing=%d", err, len(rest))
	}
	if parsed.R.Sign() <= 0 || parsed.S.Sign() <= 0 {
		t.Fatalf("r and s must both be positive: r=%v s=%v", parsed.R, parsed.S)
	}

	// The macOS client stores a certificate only when it is shaped like this
	// (DeviceIDCertificates.isWellFormed): a short-form DER SEQUENCE of at most 72 bytes.
	if sig[0] != 0x30 || int(sig[1]) != len(sig)-2 || len(sig) < 8 || len(sig) > 72 {
		t.Fatalf("the client's well-formedness check would reject this certificate: % x", sig[:2])
	}
}

// fixedSigner stands in for the KMS signer: it returns the DER encoding kms:Sign
// returns, produced outside Authority, so a certificate made this way exercises the
// seam without reaching AWS.
type fixedSigner struct {
	key *ecdsa.PrivateKey
	err error
}

func (f fixedSigner) signDigest(_ context.Context, digest []byte) ([]byte, error) {
	if f.err != nil {
		return nil, f.err
	}
	r, s, err := ecdsa.Sign(rand.Reader, f.key, digest)
	if err != nil {
		return nil, err
	}
	return asn1.Marshal(struct{ R, S *big.Int }{r, s})
}

func TestACertificateFromTheSignerSeamVerifiesWithTheExistingVerifier(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := parseKMSPublicKey(spki)
	if err != nil {
		t.Fatal(err)
	}
	a := &Authority{pub: pub, signer: fixedSigner{key: key}}

	owner := pubkey(t)
	cert, err := a.Issue(context.Background(), vectorDeviceID, owner)
	if err != nil {
		t.Fatal(err)
	}
	if !a.Verify(vectorDeviceID, owner, cert) {
		t.Fatal("a certificate signed through the seam did not verify")
	}
	if a.Verify("481930276", owner, cert) {
		t.Fatal("the certificate verified for another id")
	}
	// A signer failure must surface as an error and no certificate, never a half-written one.
	broken := &Authority{pub: pub, signer: fixedSigner{err: errors.New("kms unavailable")}}
	cert, err = broken.Issue(context.Background(), vectorDeviceID, owner)
	if err == nil || cert != "" {
		t.Fatalf("a failing signer produced a certificate: %q %v", cert, err)
	}
}

func TestThePublicKeyConversionAcceptsOnlyAP256SPKI(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := parseKMSPublicKey(spki)
	if err != nil {
		t.Fatal(err)
	}
	if !pub.Equal(&key.PublicKey) {
		t.Fatal("the DER SPKI did not round-trip to the same public key")
	}

	p384, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	wrongCurve, err := x509.MarshalPKIXPublicKey(&p384.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	for name, der := range map[string][]byte{
		"empty":        nil,
		"garbage":      []byte{0x30, 0x03, 0x02, 0x01, 0x00},
		"wrong curve":  wrongCurve,
		"a raw point":  key.PublicKey.X.Bytes(),
		"a truncation": spki[:len(spki)-4],
	} {
		if _, err := parseKMSPublicKey(der); err == nil {
			t.Errorf("accepted %s as the authority public key", name)
		}
	}
}

// rc-signal gives a whole internal call 3 s (API.md §6.1), and a hello spends it on
// POST /internal/devices/{id}/cert. If signing could outlast that, rc-signal would give
// up while rc-api still waited on KMS and could not tell a slow answer from a failed one.
func TestTheSigningBudgetFitsInsideTheInternalCallTimeout(t *testing.T) {
	var backoff time.Duration
	for attempt := 1; attempt < kmsAttempts; attempt++ {
		backoff += kmsBackoff << (attempt - 1)
	}
	worst := kmsSignTimeout*kmsAttempts + backoff
	if worst >= internalCallBudget {
		t.Fatalf("the worst-case signing call is %v, which does not fit in rc-signal's %v budget", worst, internalCallBudget)
	}
	if headroom := internalCallBudget - worst; headroom < handlerHeadroomMin {
		t.Fatalf("the worst-case signing call is %v, leaving only %v for the rest of the handler; want at least %v",
			worst, headroom, handlerHeadroomMin)
	}
	// The startup fetch is deliberately outside that budget: it runs once, before serving.
	if kmsStartupTimeout <= kmsSignTimeout {
		t.Fatalf("the startup fetch timeout %v should be more generous than a per-signature %v", kmsStartupTimeout, kmsSignTimeout)
	}
}

type codedError struct{ code string }

func (c codedError) Error() string     { return c.code }
func (c codedError) ErrorCode() string { return c.code }

func TestOnlyThrottlingAndTransientKMSFailuresAreRetried(t *testing.T) {
	for code, want := range map[string]bool{
		"ThrottlingException":        true,
		"LimitExceededException":     true,
		"KMSInternalException":       true,
		"DependencyTimeoutException": true,
		"AccessDeniedException":      false,
		"NotFoundException":          false,
		"KMSInvalidStateException":   false,
		"DisabledException":          false,
		"InvalidKeyUsageException":   false,
	} {
		if got := retryableKMSError(codedError{code: code}); got != want {
			t.Errorf("%s: retryable=%v, want %v", code, got, want)
		}
	}
	if retryableKMSError(errors.New("a plain error")) {
		t.Error("an error with no KMS code was treated as throttling")
	}
	if !retryableKMSError(errors.Join(errors.New("wrapped"), codedError{code: "ThrottlingException"})) {
		t.Error("a wrapped throttling error was not recognised")
	}
}
