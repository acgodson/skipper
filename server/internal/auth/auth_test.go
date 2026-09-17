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

func sign(t *testing.T, k *ecdsa.PrivateKey, nonce []byte) string {
	t.Helper()
	return signPurpose(t, k, protocol.PurposeHello, nonce)
}

func signPurpose(t *testing.T, k *ecdsa.PrivateKey, purpose protocol.SigningPurpose, nonce []byte) string {
	t.Helper()
	message, err := protocol.SigningMessage(purpose, nonce)
	if err != nil {
		t.Fatal(err)
	}
	return signRaw(t, k, message)
}

func signRaw(t *testing.T, k *ecdsa.PrivateKey, msg []byte) string {
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
	if err := VerifyDeviceSig(protocol.PurposeHello, pub, sign(t, k, nonce), nonce); err != nil {
		t.Fatalf("a valid signature was rejected: %v", err)
	}

	other := append([]byte{}, nonce...)
	other[0] ^= 0xff
	if err := VerifyDeviceSig(protocol.PurposeHello, pub, sign(t, k, other), nonce); err == nil {
		t.Fatal("a signature over the wrong nonce was accepted")
	}

	k2, _ := newKey(t)
	if err := VerifyDeviceSig(protocol.PurposeHello, pub, sign(t, k2, nonce), nonce); err == nil {
		t.Fatal("a signature from the wrong key was accepted")
	}

	_, pub2 := newKey(t)
	if err := VerifyDeviceSig(protocol.PurposeHello, pub2, sign(t, k, nonce), nonce); err == nil {
		t.Fatal("a mismatched pubkey was accepted")
	}

	good := sign(t, k, nonce)
	raw, _ := base64.StdEncoding.DecodeString(good)
	raw[len(raw)-1] ^= 0x01
	if err := VerifyDeviceSig(protocol.PurposeHello, pub, base64.StdEncoding.EncodeToString(raw), nonce); err == nil {
		t.Fatal("a tampered signature was accepted")
	}

	for _, bad := range []string{"", "not base64!!", base64.StdEncoding.EncodeToString([]byte("hello"))} {
		if err := VerifyDeviceSig(protocol.PurposeHello, bad, good, nonce); err == nil {
			t.Fatalf("garbage pubkey %q was accepted", bad)
		}
		if err := VerifyDeviceSig(protocol.PurposeHello, pub, bad, nonce); err == nil {
			t.Fatalf("garbage signature %q was accepted", bad)
		}
	}

	k384, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki384, _ := x509.MarshalPKIXPublicKey(&k384.PublicKey)
	if _, err := ParsePubkey(base64.StdEncoding.EncodeToString(spki384)); err == nil {
		t.Fatal("a P-384 key was accepted")
	}
}

func TestVerifyDeviceSigIsDomainSeparated(t *testing.T) {
	k, pub := newKey(t)
	nonce, _, err := NewNonce()
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyDeviceSig(protocol.PurposeHello, pub, signRaw(t, k, nonce), nonce); err == nil {
		t.Fatal("a signature over the bare nonce (v2) was accepted")
	}
	nonces := []protocol.SigningPurpose{protocol.PurposeHello, protocol.PurposeRegister, protocol.PurposeAPIChallenge}
	for _, signedAs := range nonces {
		sig := signPurpose(t, k, signedAs, nonce)
		for _, checkedAs := range nonces {
			err := VerifyDeviceSig(checkedAs, pub, sig, nonce)
			if (signedAs == checkedAs) != (err == nil) {
				t.Fatalf("signed as %s, checked as %s: err=%v", signedAs, checkedAs, err)
			}
		}
	}

	sdpPayload := []byte("8c7f1a2b3c4d5e6f708192a3b4c5d6e7|answer|sha-256 AB")
	sdpSig := signRaw(t, k, append([]byte("skipperdesk/sdp/v1|"), sdpPayload...))
	if err := VerifyDeviceSig(protocol.PurposeSDP, pub, sdpSig, sdpPayload); err == nil {
		t.Fatal("the server verified an sdp-purpose signature; it never should")
	}
}

func TestVerifyDeviceSigRejectsNoncesThatAreNot32Bytes(t *testing.T) {
	k, pub := newKey(t)
	forged := []byte("skipperdesk/sdp/v1|8c7f1a2b3c4d5e6f708192a3b4c5d6e7|answer|sha-256 AB")
	for _, nonce := range [][]byte{nil, make([]byte, 31), make([]byte, 33), forged} {
		sig := signRaw(t, k, append([]byte("skipperdesk/hello/v1|"), nonce...))
		if err := VerifyDeviceSig(protocol.PurposeHello, pub, sig, nonce); err == nil {
			t.Fatalf("a %d-byte nonce was accepted", len(nonce))
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

	claims2 := claims
	claims2.Nonce = "n2"
	if s.Mint(claims2) == tok {
		t.Fatal("rotating the nonce did not change the token")
	}

	if _, err := NewSigner([]byte("secret-two-secret-two-secret-two")).Parse(tok); err == nil {
		t.Fatal("a token was accepted under the wrong secret")
	}

	body, mac, _ := strings.Cut(tok, ".")
	raw, _ := base64.RawURLEncoding.DecodeString(body)
	tampered := strings.Replace(string(raw), "481930275", "999999999", 1)
	forged := base64.RawURLEncoding.EncodeToString([]byte(tampered)) + "." + mac
	if _, err := s.Parse(forged); err == nil {
		t.Fatal("a token whose deviceId was swapped was accepted")
	}

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

func TestOneKeyHasExactlyOneAcceptedSpelling(t *testing.T) {
	k, pub := newKey(t)
	if _, err := ParsePubkey(pub); err != nil {
		t.Fatalf("canonical key refused: %v", err)
	}
	der, _ := base64.StdEncoding.DecodeString(pub)
	compressed := append([]byte{}, der[:25]...)
	compressed[1], compressed[24] = 0x39, 0x22
	compressed = append(compressed, 0x00, 0x02|byte(k.PublicKey.Y.Bit(0)))
	compressed = append(compressed, der[27:59]...)
	variants := map[string]string{
		"newline inside":   pub[:40] + "\n" + pub[40:],
		"trailing newline": pub + "\n",
		"unpadded":         strings.TrimRight(pub, "="),
		"url alphabet":     base64.URLEncoding.EncodeToString(der),
		"leading space":    " " + pub,
		"compressed point": base64.StdEncoding.EncodeToString(compressed),
	}
	for name, v := range variants {
		if v == pub {
			continue
		}
		if _, err := ParsePubkey(v); err == nil {
			t.Errorf("%s: a second spelling of the same key was accepted", name)
		}
	}
	nonce, _, _ := NewNonce()
	if err := VerifyDeviceSig(protocol.PurposeHello, pub[:40]+"\n"+pub[40:], sign(t, k, nonce), nonce); err == nil {
		t.Error("a signature verified under a non-canonical key string")
	}
}

func TestTurnCredsMatchCoturnRESTAuth(t *testing.T) {
	now := time.Unix(1_755_600_000, 0)
	user, cred, exp := TurnCreds("s3cr3t", "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", now, 2*time.Hour)

	wantExpUnix := now.Add(2 * time.Hour).Unix()
	if exp.Unix() != wantExpUnix {
		t.Fatalf("expiry = %d, want %d", exp.Unix(), wantExpUnix)
	}
	wantUser := strconv.FormatInt(wantExpUnix, 10) + ":8c7f1a2b3c4d5e6f708192a3b4c5d6e7"
	if user != wantUser {
		t.Fatalf("username = %q, want %q", user, wantUser)
	}

	m := hmac.New(sha1.New, []byte("s3cr3t"))
	m.Write([]byte(wantUser))
	if want := base64.StdEncoding.EncodeToString(m.Sum(nil)); cred != want {
		t.Fatalf("credential = %q, want %q", cred, want)
	}

	if _, c2, _ := TurnCreds("other", "8c7f1a2b3c4d5e6f708192a3b4c5d6e7", now, 2*time.Hour); c2 == cred {
		t.Fatal("changing the TURN secret did not change the credential")
	}
	if _, c3, _ := TurnCreds("s3cr3t", "9c7f1a2b3c4d5e6f708192a3b4c5d6e7", now, 2*time.Hour); c3 == cred {
		t.Fatal("changing the session did not change the credential")
	}
}
