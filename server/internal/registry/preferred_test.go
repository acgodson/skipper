package registry

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"rc-signal/internal/apidb"
	"rc-signal/internal/apisrv"
	"rc-signal/internal/clockx"
	"rc-signal/internal/idcert"
	"rc-signal/internal/idp"
	"rc-signal/internal/internalapi"
	"rc-signal/internal/store"
	protocol "rcprotocol"
)

func newPubkey(t *testing.T) string {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(spki)
}

type opener func(t *testing.T, authority *idcert.Authority, claims string) Registry

func localBackend(t *testing.T, authority *idcert.Authority, claims string) Registry {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "rc.db"), claims)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return NewLocal(st, clockx.NewFake(), authority)
}

func apiBackend(t *testing.T, authority *idcert.Authority, claims string) Registry {
	t.Helper()
	db, err := apidb.Open(filepath.Join(t.TempDir(), "api.db"), claims)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	api, err := apisrv.New(apisrv.Options{
		DB: db, IdP: idp.Dev{}, IDCert: authority, InternalToken: token, HardwareSalt: []byte("salt"),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(api.InternalHandler())
	t.Cleanup(srv.Close)
	client, err := internalapi.New(srv.URL, token)
	if err != nil {
		t.Fatal(err)
	}
	return NewHTTP(client, clockx.NewFake())
}

func TestAClaimedDeviceIDSurvivesARegistryResetInBothRegistries(t *testing.T) {
	for name, open := range map[string]opener{"local": localBackend, "rc-api": apiBackend} {
		t.Run(name, func(t *testing.T) {
			authority, err := idcert.Ephemeral()
			if err != nil {
				t.Fatal(err)
			}
			ctx := context.Background()
			claims := filepath.Join(t.TempDir(), "claims.db")
			owner, squatter := newPubkey(t), newPubkey(t)

			before := open(t, authority, claims)
			first, err := before.Register(ctx, Registration{Pubkey: owner, PreferredDeviceID: "481930275"})
			if err != nil || first.Existing || first.Device.DeviceID == "481930275" {
				t.Fatalf("an uncertified preferred id was honoured: %+v err=%v", first, err)
			}
			id, cert := first.Device.DeviceID, first.Device.IDCert
			if !authority.Verify(id, owner, cert) {
				t.Fatal("register carried no valid certificate")
			}
			looked, err := before.Lookup(ctx, id)
			if err != nil || looked.Pubkey != owner || looked.IDCert != "" {
				t.Fatalf("a lookup must not sign: %+v err=%v", looked, err)
			}
			certified, err := before.Certify(ctx, id, owner)
			if err != nil || !authority.Verify(id, owner, certified.IDCert) {
				t.Fatalf("certify for the owner: %+v err=%v", certified, err)
			}
			for _, wrong := range [][2]string{{id, squatter}, {"999999999", owner}} {
				if got, err := before.Certify(ctx, wrong[0], wrong[1]); !errors.Is(err, ErrNotFound) || got.IDCert != "" {
					t.Fatalf("certify %v = %+v err=%v, want not found", wrong, got, err)
				}
			}

			after := open(t, authority, claims)
			if _, err := after.Lookup(ctx, id); !errors.Is(err, ErrNotFound) {
				t.Fatalf("the reset registry still knows %s: %v", id, err)
			}
			stolen, err := after.Register(ctx, Registration{Pubkey: squatter, PreferredDeviceID: id, IDCert: cert})
			if err != nil || stolen.Device.DeviceID == id || !protocol.ValidDeviceID(stolen.Device.DeviceID) {
				t.Fatalf("another key's certificate claimed the id: %+v err=%v", stolen, err)
			}
			second, err := authority.Issue(id, squatter)
			if err != nil {
				t.Fatal(err)
			}
			other := newPubkey(t)
			forged, err := after.Register(ctx, Registration{Pubkey: other, PreferredDeviceID: id, IDCert: second})
			if err != nil || forged.Device.DeviceID == id {
				t.Fatalf("a second valid certificate took a claimed id: %+v err=%v", forged, err)
			}

			restored, err := after.Register(ctx, Registration{Pubkey: owner, PreferredDeviceID: id, IDCert: cert})
			if err != nil || restored.Existing || restored.Device.DeviceID != id || restored.Device.Pubkey != owner {
				t.Fatalf("the claimant did not get its id back: %+v err=%v", restored, err)
			}
			if got, err := after.Lookup(ctx, id); err != nil || got.Pubkey != owner {
				t.Fatalf("lookup after restore = %+v err=%v", got, err)
			}
			kept, err := after.Register(ctx, Registration{Pubkey: owner, PreferredDeviceID: "222222222"})
			if err != nil || !kept.Existing || kept.Device.DeviceID != id {
				t.Fatalf("a known key asking for another id = %+v err=%v", kept, err)
			}
		})
	}
}
