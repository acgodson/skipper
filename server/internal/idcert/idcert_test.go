package idcert

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func pubkey(t *testing.T) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func writeKey(t *testing.T) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "id-cert.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestACertificateBindsExactlyOneIDToOneKey(t *testing.T) {
	path := writeKey(t)
	a, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	owner, stranger := pubkey(t), pubkey(t)
	cert, err := a.Issue("481930275", owner)
	if err != nil {
		t.Fatal(err)
	}
	if !a.Verify("481930275", owner, cert) {
		t.Fatal("a fresh certificate did not verify")
	}
	reloaded, err := Load(path)
	if err != nil || !reloaded.Verify("481930275", owner, cert) {
		t.Fatalf("the certificate did not survive a restart with the same key file: %v", err)
	}
	other, _ := Ephemeral()
	for name, ok := range map[string]bool{
		"another id":        a.Verify("481930276", owner, cert),
		"another key":       a.Verify("481930275", stranger, cert),
		"another authority": other.Verify("481930275", owner, cert),
		"empty":             a.Verify("481930275", owner, ""),
		"garbage":           a.Verify("481930275", owner, "not base64!"),
	} {
		if ok {
			t.Errorf("certificate verified for %s", name)
		}
	}
	if _, err := a.Issue("12345", owner); err == nil {
		t.Error("issued a certificate for a malformed id")
	}
	if _, err := a.Issue("481930275", "AAAA"); err == nil {
		t.Error("issued a certificate for a malformed key")
	}
}

func TestOpenRequiresAKeyOutsideLocalMode(t *testing.T) {
	if _, _, err := Open("", false); err == nil {
		t.Fatal("started without a key in secure mode")
	}
	if a, ephemeral, err := Open("", true); err != nil || a == nil || !ephemeral {
		t.Fatalf("local mode: %v %v %v", a, ephemeral, err)
	}
	bad := filepath.Join(t.TempDir(), "bad.pem")
	_ = os.WriteFile(bad, []byte("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n"), 0o600)
	if _, _, err := Open(bad, true); err == nil {
		t.Fatal("accepted a non-PKCS#8 key file")
	}
}
