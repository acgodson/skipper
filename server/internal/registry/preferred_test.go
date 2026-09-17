package registry

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"io"
	"log/slog"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"rc-signal/internal/apidb"
	"rc-signal/internal/apisrv"
	"rc-signal/internal/clockx"
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

func localRegistry(t *testing.T) Registry {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "rc.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return NewLocal(st, clockx.NewFake())
}

func apiRegistry(t *testing.T) Registry {
	t.Helper()
	db, err := apidb.Open(filepath.Join(t.TempDir(), "api.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	api, err := apisrv.New(apisrv.Options{
		DB: db, IdP: idp.Dev{}, InternalToken: token, HardwareSalt: []byte("salt"),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)
	client, err := internalapi.New(srv.URL, token)
	if err != nil {
		t.Fatal(err)
	}
	return NewHTTP(client, clockx.NewFake())
}

func TestPreferredDeviceIDInBothRegistries(t *testing.T) {
	for name, open := range map[string]func(*testing.T) Registry{"local": localRegistry, "rc-api": apiRegistry} {
		t.Run(name, func(t *testing.T) {
			reg := open(t)
			ctx := context.Background()
			owner, stranger := newPubkey(t), newPubkey(t)

			honoured, existing, err := reg.Register(ctx, owner, "", "481930275")
			if err != nil || existing || honoured.DeviceID != "481930275" || honoured.Pubkey != owner {
				t.Fatalf("free id for a new key = %+v existing=%v err=%v", honoured, existing, err)
			}

			known, existing, err := reg.Register(ctx, owner, "", "222222222")
			if err != nil || !existing || known.DeviceID != "481930275" {
				t.Fatalf("known key asking for another id = %+v existing=%v err=%v", known, existing, err)
			}

			other, existing, err := reg.Register(ctx, stranger, "", "481930275")
			if err != nil || existing || other.DeviceID == "481930275" || !protocol.ValidDeviceID(other.DeviceID) {
				t.Fatalf("stranger asking for a held id = %+v existing=%v err=%v", other, existing, err)
			}
			if got, err := reg.Lookup(ctx, "481930275"); err != nil || got.Pubkey != owner {
				t.Fatalf("the held id changed hands: %+v err=%v", got, err)
			}
		})
	}
}
