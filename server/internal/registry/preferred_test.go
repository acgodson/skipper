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
	"time"

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

type backendUnderTest struct {
	reg   Registry
	plant func(id, pubkey string)
}

type opener func(t *testing.T, authority *idcert.Authority) backendUnderTest

func localBackend(t *testing.T, authority *idcert.Authority) backendUnderTest {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "rc.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return backendUnderTest{
		reg: NewLocal(st, clockx.NewFake(), authority),
		plant: func(id, pubkey string) {
			if _, _, err := st.Register(pubkey, "", id, time.Now()); err != nil {
				t.Fatal(err)
			}
		},
	}
}

func apiBackend(t *testing.T, authority *idcert.Authority) backendUnderTest {
	t.Helper()
	db, err := apidb.Open(filepath.Join(t.TempDir(), "api.db"))
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
	return backendUnderTest{
		reg: NewHTTP(client, clockx.NewFake()),
		plant: func(id, pubkey string) {
			if _, _, err := db.RegisterDevice(apidb.Device{Pubkey: pubkey, CreatedAt: 1}, id); err != nil {
				t.Fatal(err)
			}
		},
	}
}

func TestADeviceIDCertificateRestoresTheIDAfterAResetInBothRegistries(t *testing.T) {
	for name, open := range map[string]opener{"local": localBackend, "rc-api": apiBackend} {
		t.Run(name, func(t *testing.T) {
			authority, err := idcert.Ephemeral()
			if err != nil {
				t.Fatal(err)
			}
			ctx := context.Background()
			owner, squatter := newPubkey(t), newPubkey(t)

			before := open(t, authority)
			first, err := before.reg.Register(ctx, Registration{Pubkey: owner, PreferredDeviceID: "481930275"})
			if err != nil || first.Existing || first.Device.DeviceID == "481930275" {
				t.Fatalf("an uncertified preferred id was honoured: %+v err=%v", first, err)
			}
			id, cert := first.Device.DeviceID, first.Device.IDCert
			if !authority.Verify(id, owner, cert) {
				t.Fatal("register_ok carried no valid certificate")
			}
			looked, err := before.reg.Lookup(ctx, id)
			if err != nil || !authority.Verify(id, owner, looked.IDCert) {
				t.Fatalf("lookup carried no valid certificate: %+v err=%v", looked, err)
			}

			after := open(t, authority)
			stolen, err := after.reg.Register(ctx, Registration{Pubkey: squatter, PreferredDeviceID: id, IDCert: cert})
			if err != nil || stolen.Device.DeviceID == id || !protocol.ValidDeviceID(stolen.Device.DeviceID) {
				t.Fatalf("another key's certificate claimed the id: %+v err=%v", stolen, err)
			}
			after.plant(id, newPubkey(t))

			restored, err := after.reg.Register(ctx, Registration{Pubkey: owner, PreferredDeviceID: id, IDCert: cert})
			if err != nil || restored.Existing || restored.Device.DeviceID != id || restored.Device.Pubkey != owner {
				t.Fatalf("the certified owner did not get its id back over the squatter: %+v err=%v", restored, err)
			}
			if got, err := after.reg.Lookup(ctx, id); err != nil || got.Pubkey != owner {
				t.Fatalf("lookup after restore = %+v err=%v", got, err)
			}

			kept, err := after.reg.Register(ctx, Registration{Pubkey: owner, PreferredDeviceID: "222222222"})
			if err != nil || !kept.Existing || kept.Device.DeviceID != id {
				t.Fatalf("a known key asking for another id = %+v err=%v", kept, err)
			}
		})
	}
}
