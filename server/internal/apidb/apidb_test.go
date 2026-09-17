package apidb

import (
	"path/filepath"
	"testing"

	protocol "rcprotocol"
)

func register(t *testing.T, d *DB, pubkey, preferred string) (*Device, bool) {
	t.Helper()
	dev, existing, err := d.RegisterDevice(Device{Pubkey: pubkey, CreatedAt: 1}, preferred)
	if err != nil {
		t.Fatal(err)
	}
	return dev, existing
}

func TestRegisterDevicePreferredIDAndTombstone(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "api.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	if dev, existing := register(t, d, "PK-A", "481930275"); existing || dev.DeviceID != "481930275" {
		t.Fatalf("free preferred id = %+v existing=%v", dev, existing)
	}
	if dev, existing := register(t, d, "PK-A", "222222222"); !existing || dev.DeviceID != "481930275" {
		t.Fatalf("known key = %+v existing=%v", dev, existing)
	}
	if dev, _ := register(t, d, "PK-B", "481930275"); dev.DeviceID == "481930275" || !protocol.ValidDeviceID(dev.DeviceID) {
		t.Fatalf("held id handed to a stranger: %+v", dev)
	}

	if _, err := d.db.Exec(`DELETE FROM devices WHERE device_id = ?`, "481930275"); err != nil {
		t.Fatal(err)
	}
	if dev, _ := register(t, d, "PK-C", "481930275"); dev.DeviceID == "481930275" {
		t.Fatalf("tombstoned id handed to another key: %+v", dev)
	}
	if dev, existing := register(t, d, "PK-A", "481930275"); existing || dev.DeviceID != "481930275" {
		t.Fatalf("original key could not reclaim its tombstoned id: %+v existing=%v", dev, existing)
	}
}
