package idp

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const (
	testAudience = "4example0app0client0id"
	testKid      = "test-kid"
)

// pool stands in for a Cognito user pool: it serves one JWKS and mints tokens
// signed by the key in it, so a test can say exactly which claims arrive.
type pool struct {
	key    *rsa.PrivateKey
	issuer string
	client *http.Client
}

func newPool(t *testing.T) *pool {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	p := &pool{key: key}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/jwks.json", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "kid": testKid,
			"n": base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString([]byte{0x01, 0x00, 0x01}),
		}}})
	})
	srv := httptest.NewTLSServer(mux)
	t.Cleanup(srv.Close)
	p.issuer = srv.URL
	p.client = srv.Client()
	return p
}

func (p *pool) provider(t *testing.T) *Cognito {
	t.Helper()
	c, err := NewCognito(p.issuer, testAudience)
	if err != nil {
		t.Fatal(err)
	}
	c.client = p.client
	return c
}

func (p *pool) token(t *testing.T, kid string, claims map[string]any) string {
	t.Helper()
	encode := func(v any) string {
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(raw)
	}
	signed := encode(map[string]string{"alg": "RS256", "kid": kid}) + "." + encode(claims)
	sum := sha256.Sum256([]byte(signed))
	sig, err := rsa.SignPKCS1v15(rand.Reader, p.key, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return signed + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func (p *pool) idTokenClaims() map[string]any {
	return map[string]any{
		"iss": p.issuer, "sub": "11111111-2222-3333-4444-555555555555",
		"aud": testAudience, "token_use": "id", "email": "Owner@Example.com",
		"exp": time.Now().Add(time.Hour).Unix(),
	}
}

// An access token from the same pool verifies under the same keys and names the
// same app client. `token_use` is the only claim that separates the two, so it is
// the only thing that can refuse one.
func (p *pool) accessTokenClaims() map[string]any {
	return map[string]any{
		"iss": p.issuer, "sub": "11111111-2222-3333-4444-555555555555",
		"client_id": testAudience, "token_use": "access", "scope": "openid email profile",
		"exp": time.Now().Add(time.Hour).Unix(),
	}
}

func TestCognitoAcceptsTheIDToken(t *testing.T) {
	p := newPool(t)
	session, err := p.provider(t).UserSession(context.Background(), p.token(t, testKid, p.idTokenClaims()))
	if err != nil {
		t.Fatalf("a well-formed ID token was refused: %v", err)
	}
	if session.AccountID != "11111111-2222-3333-4444-555555555555" || session.Email != "owner@example.com" {
		t.Fatalf("session = %+v", session)
	}
}

func TestCognitoRefusesAnythingButAnIDToken(t *testing.T) {
	p := newPool(t)
	cognito := p.provider(t)

	withEmail := p.accessTokenClaims()
	withEmail["email"] = "owner@example.com"

	noTokenUse := p.idTokenClaims()
	delete(noTokenUse, "token_use")

	// `client_id` is an access-token claim. It cannot appear in an ID token, so
	// once only ID tokens are accepted no audience can ever be matched through it
	// — which is why the branch that did so is gone rather than merely narrowed.
	clientIDOnly := p.idTokenClaims()
	delete(clientIDOnly, "aud")
	clientIDOnly["client_id"] = testAudience

	refreshLike := p.idTokenClaims()
	refreshLike["token_use"] = "refresh"

	wrongAudience := p.idTokenClaims()
	wrongAudience["aud"] = "some-other-app-client"

	for name, claims := range map[string]map[string]any{
		"an access token":                         p.accessTokenClaims(),
		"an access token carrying an email":       withEmail,
		"a token with no token_use at all":        noTokenUse,
		"an ID token audience-bound by client_id": clientIDOnly,
		"any other token_use":                     refreshLike,
		"another app client's ID token":           wrongAudience,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := cognito.UserSession(context.Background(), p.token(t, testKid, claims)); !errors.Is(err, ErrUnauthenticated) {
				t.Fatalf("%s was accepted (err = %v)", name, err)
			}
		})
	}
}

func TestCognitoRefusesForeignAndExpiredTokens(t *testing.T) {
	p := newPool(t)
	cognito := p.provider(t)

	expired := p.idTokenClaims()
	expired["exp"] = time.Now().Add(-10 * time.Minute).Unix()

	foreignIssuer := p.idTokenClaims()
	foreignIssuer["iss"] = "https://cognito-idp.eu-west-2.amazonaws.com/eu-west-2_someoneelse"

	noSubject := p.idTokenClaims()
	delete(noSubject, "sub")

	for name, claims := range map[string]map[string]any{
		"expired":      expired,
		"another pool": foreignIssuer,
		"no subject":   noSubject,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := cognito.UserSession(context.Background(), p.token(t, testKid, claims)); !errors.Is(err, ErrUnauthenticated) {
				t.Fatalf("%s was accepted (err = %v)", name, err)
			}
		})
	}

	if _, err := cognito.UserSession(context.Background(), p.token(t, "unknown-kid", p.idTokenClaims())); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("a token signed under an unknown kid was accepted: %v", err)
	}
}
