package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"strconv"
	"strings"
	"testing"
	"time"

	"rcprotocol"
)

func newKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return k, base64.StdEncoding.EncodeToString(spki)
}

func sign(t *testing.T, k *ecdsa.PrivateKey, msg []byte) string {
	t.Helper()
	sum := sha256.Sum256(msg)
	sig, err := ecdsa.SignASN1(rand.Reader, k, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

func TestVerifyDeviceSig(t *testing.T) {
	k, pub := newKey(t)
	nonce, _, err := NewNonce()
	if err != nil {
		t.Fatal(err)
	}
	if len(nonce) != 32 {
		t.Fatalf("nonce length = %d, want 32", len(nonce))
	}
	if err := VerifyDeviceSig(pub, sign(t, k, nonce), nonce); err != nil {
		t.Fatalf("a valid signature was rejected: %v", err)
	}

	// Signature over different bytes.
	other := append([]byte{}, nonce...)
	other[0] ^= 0xff
	if err := VerifyDeviceSig(pub, sign(t, k, other), nonce); err == nil {
		t.Fatal("a signature over the wrong nonce was accepted")
	}
	// Signature from a different key.
	k2, _ := newKey(t)
	if err := VerifyDeviceSig(pub, sign(t, k2, nonce), nonce); err == nil {
		t.Fatal("a signature from the wrong key was accepted")
	}
	// Right signature, wrong advertised key.
	_, pub2 := newKey(t)
	if err := VerifyDeviceSig(pub2, sign(t, k, nonce), nonce); err == nil {
		t.Fatal("a mismatched pubkey was accepted")
	}
	// Truncated / mangled signature bytes.
	good := sign(t, k, nonce)
	raw, _ := base64.StdEncoding.DecodeString(good)
	raw[len(raw)-1] ^= 0x01
	if err := VerifyDeviceSig(pub, base64.StdEncoding.EncodeToString(raw), nonce); err == nil {
		t.Fatal("a tampered signature was accepted")
	}
	// Garbage inputs must return an error, never panic.
	for _, bad := range []string{"", "not base64!!", base64.StdEncoding.EncodeToString([]byte("hello"))} {
		if err := VerifyDeviceSig(bad, good, nonce); err == nil {
			t.Fatalf("garbage pubkey %q was accepted", bad)
		}
		if err := VerifyDeviceSig(pub, bad, nonce); err == nil {
			t.Fatalf("garbage signature %q was accepted", bad)
		}
	}
	// An RSA or non-P256 key must be refused.
	k384, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki384, _ := x509.MarshalPKIXPublicKey(&k384.PublicKey)
	if _, err := ParsePubkey(base64.StdEncoding.EncodeToString(spki384)); err == nil {
		t.Fatal("a P-384 key was accepted")
	}
}

func TestVerifyCode(t *testing.T) {
	v, err := MakeVerifier("SW7K2M9Q")
	if err != nil {
		t.Fatal(err)
	}
	if v.Alg != protocol.AlgArgon2id || v.Time != 3 || v.MemKiB != 65536 || v.Len != 32 {
		t.Fatalf("unexpected verifier parameters: %+v", v)
	}
	if !VerifyCode(v, "SW7K2M9Q") {
		t.Fatal("the correct code was rejected")
	}
	for _, wrong := range []string{"SW7K2M9R", "sw7k2m9q", "", "SW7K2M9", "SW7K2M9QQ"} {
		if VerifyCode(v, wrong) {
			t.Fatalf("wrong code %q was accepted", wrong)
		}
	}
	// Two verifiers for the same code differ (random salt) but both verify.
	v2, _ := MakeVerifier("SW7K2M9Q")
	if v2.Salt == v.Salt || v2.Hash == v.Hash {
		t.Fatal("verifiers for the same code must not be identical (salt reuse)")
	}
	if !VerifyCode(v2, "SW7K2M9Q") {
		t.Fatal("the second verifier rejected the correct code")
	}
	// Structurally broken verifiers must fail closed.
	for _, mangle := range []func(protocol.CodeVerifier) protocol.CodeVerifier{
		func(c protocol.CodeVerifier) protocol.CodeVerifier { c.Alg = "bcrypt"; return c },
		func(c protocol.CodeVerifier) protocol.CodeVerifier { c.Salt = "!!!"; return c },
		func(c protocol.CodeVerifier) protocol.CodeVerifier { c.Hash = "!!!"; return c },
		func(c protocol.CodeVerifier) protocol.CodeVerifier { c.MemKiB = 16; return c },
		func(c protocol.CodeVerifier) protocol.CodeVerifier { c.Len = 8; return c },
		func(c protocol.CodeVerifier) protocol.CodeVerifier {
			c.Time = 3
			c.MemKiB = 65536
			c.Len = 64
			return c
		},
	} {
		if VerifyCode(mangle(v), "SW7K2M9Q") {
			t.Fatal("a broken verifier accepted a code")
		}
	}
}

func TestTokenMintAndParse(t *testing.T) {
	s := NewSigner([]byte("secret-one-secret-one-secret-one"))
	exp := time.Now().Add(10 * time.Minute).Truncate(time.Second)
	claims := TokenClaims{SessionID: "abc123", DeviceID: "481930275", Expiry: exp, Epoch: 7, Nonce: "n1"}
	tok := s.Mint(claims)

	if !strings.Contains(tok, ".") {
		t.Fatalf("token %q has no MAC separator", tok)
	}
	got, err := s.Parse(tok)
	if err != nil {
		t.Fatalf("parsing a freshly minted token failed: %v", err)
	}
	if got.SessionID != "abc123" || got.DeviceID != "481930275" || got.Epoch != 7 || got.Nonce != "n1" {
		t.Fatalf("round-tripped claims = %+v, want %+v", got, claims)
	}
	if !got.Expiry.Equal(exp) {
		t.Fatalf("expiry = %v, want %v", got.Expiry, exp)
	}

	// Different claims produce different tokens.
	claims2 := claims
	claims2.Nonce = "n2"
	if s.Mint(claims2) == tok {
		t.Fatal("rotating the nonce did not change the token")
	}

	// A different secret cannot verify it.
	if _, err := NewSigner([]byte("secret-two-secret-two-secret-two")).Parse(tok); err == nil {
		t.Fatal("a token was accepted under the wrong secret")
	}

	// Tampering with the body invalidates the MAC.
	body, mac, _ := strings.Cut(tok, ".")
	raw, _ := base64.RawURLEncoding.DecodeString(body)
	tampered := strings.Replace(string(raw), "481930275", "999999999", 1)
	forged := base64.RawURLEncoding.EncodeToString([]byte(tampered)) + "." + mac
	if _, err := s.Parse(forged); err == nil {
		t.Fatal("a token whose deviceId was swapped was accepted")
	}
	// Tampering with the MAC too.
	macRaw := []byte(mac)
	macRaw[0] ^= 0x01
	if _, err := s.Parse(body + "." + string(macRaw)); err == nil {
		t.Fatal("a token with a modified MAC was accepted")
	}
	for _, bad := range []string{"", "nodot", "....", "!!!.###"} {
		if _, err := s.Parse(bad); err == nil {
			t.Fatalf("malformed token %q was accepted", bad)
		}
	}
}

func TestTurnCredsMatchCoturnRESTAuth(t *testing.T) {
	now := time.Unix(1_755_600_000, 0)
	user, cred, exp := TurnCreds("s3cr3t", "481930275", now, 12*time.Hour)

	wantExpUnix := now.Add(12 * time.Hour).Unix()
	if exp.Unix() != wantExpUnix {
		t.Fatalf("expiry = %d, want %d", exp.Unix(), wantExpUnix)
	}
	wantUser := strconv.FormatInt(wantExpUnix, 10) + ":481930275"
	if user != wantUser {
		t.Fatalf("username = %q, want %q", user, wantUser)
	}
	// Independently recompute the credential.
	m := hmac.New(sha1.New, []byte("s3cr3t"))
	m.Write([]byte(wantUser))
	if want := base64.StdEncoding.EncodeToString(m.Sum(nil)); cred != want {
		t.Fatalf("credential = %q, want %q", cred, want)
	}
	// A different secret or device yields a different credential.
	if _, c2, _ := TurnCreds("other", "481930275", now, 12*time.Hour); c2 == cred {
		t.Fatal("changing the TURN secret did not change the credential")
	}
	if _, c3, _ := TurnCreds("s3cr3t", "481930276", now, 12*time.Hour); c3 == cred {
		t.Fatal("changing the deviceId did not change the credential")
	}
}
