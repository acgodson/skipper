package idp

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	jwksCacheTTL  = 10 * time.Minute
	jwksMaxBytes  = 256 * 1024
	clockSkewSec  = 60
	jwksFetchTime = 5 * time.Second
)

type Cognito struct {
	issuer   string
	audience string
	client   *http.Client

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

func NewCognito(issuer, audience string) (*Cognito, error) {
	issuer = strings.TrimRight(strings.TrimSpace(issuer), "/")
	if issuer == "" || !strings.HasPrefix(issuer, "https://") {
		return nil, fmt.Errorf("cognito issuer must be an https URL, got %q", issuer)
	}
	if strings.TrimSpace(audience) == "" {
		return nil, fmt.Errorf("cognito audience is required")
	}
	return &Cognito{issuer: issuer, audience: audience,
		client: &http.Client{Timeout: jwksFetchTime}, keys: map[string]*rsa.PublicKey{}}, nil
}

func (c *Cognito) Name() string { return "cognito" }

func (c *Cognito) UserSession(ctx context.Context, bearer string) (Session, error) {
	head, claims, signed, sig, err := splitJWT(bearer)
	if err != nil {
		return Session{}, err
	}
	if head.Alg != "RS256" || head.Kid == "" {
		return Session{}, ErrUnauthenticated
	}
	key, err := c.key(ctx, head.Kid)
	if err != nil {
		return Session{}, err
	}
	sum := sha256.Sum256([]byte(signed))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, sum[:], sig); err != nil {
		return Session{}, ErrUnauthenticated
	}
	now := time.Now().Unix()
	if claims.Iss != c.issuer || claims.Exp < now-clockSkewSec || claims.Sub == "" {
		return Session{}, ErrUnauthenticated
	}
	if claims.Aud != c.audience && claims.ClientID != c.audience {
		return Session{}, ErrUnauthenticated
	}
	if claims.Email == "" {
		return Session{}, fmt.Errorf("%w: the token carries no email claim", ErrUnauthenticated)
	}
	return Session{AccountID: claims.Sub, Email: strings.ToLower(claims.Email)}, nil
}

type jwtHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
}

type jwtClaims struct {
	Iss      string `json:"iss"`
	Sub      string `json:"sub"`
	Aud      string `json:"aud"`
	ClientID string `json:"client_id"`
	Email    string `json:"email"`
	Exp      int64  `json:"exp"`
}

func splitJWT(token string) (jwtHeader, jwtClaims, string, []byte, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 3 {
		return jwtHeader{}, jwtClaims{}, "", nil, ErrUnauthenticated
	}
	var head jwtHeader
	var claims jwtClaims
	headBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || json.Unmarshal(headBytes, &head) != nil {
		return head, claims, "", nil, ErrUnauthenticated
	}
	claimBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(claimBytes, &claims) != nil {
		return head, claims, "", nil, ErrUnauthenticated
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return head, claims, "", nil, ErrUnauthenticated
	}
	return head, claims, parts[0] + "." + parts[1], sig, nil
}

func (c *Cognito) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.Lock()
	key, ok := c.keys[kid]
	fresh := time.Since(c.fetched) < jwksCacheTTL
	c.mu.Unlock()
	if ok && fresh {
		return key, nil
	}
	keys, err := c.fetchJWKS(ctx)
	if err != nil {
		if ok {
			return key, nil
		}
		return nil, err
	}
	c.mu.Lock()
	c.keys = keys
	c.fetched = time.Now()
	key, ok = c.keys[kid]
	c.mu.Unlock()
	if !ok {
		return nil, ErrUnauthenticated
	}
	return key, nil
}

func (c *Cognito) fetchJWKS(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.issuer+"/.well-known/jwks.json", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks: unexpected status %d", resp.StatusCode)
	}
	var doc struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, jwksMaxBytes)).Decode(&doc); err != nil {
		return nil, fmt.Errorf("jwks: %w", err)
	}
	out := map[string]*rsa.PublicKey{}
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		n, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil {
			continue
		}
		e, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil || len(e) == 0 || len(e) > 4 {
			continue
		}
		padded := make([]byte, 4)
		copy(padded[4-len(e):], e)
		out[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(binary.BigEndian.Uint32(padded))}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("jwks: no usable RSA keys")
	}
	return out, nil
}
