package deviceid

import (
	"testing"

	protocol "rcprotocol"
)

type memoryLedger struct {
	live   map[string]string
	claims map[string]string
}

func newMemoryLedger() *memoryLedger {
	return &memoryLedger{live: map[string]string{}, claims: map[string]string{}}
}

func (m *memoryLedger) IDForPubkey(pubkey string) (string, bool, error) {
	for id, pk := range m.live {
		if pk == pubkey {
			return id, true, nil
		}
	}
	return "", false, nil
}

func (m *memoryLedger) Claim(id, pubkey string) error {
	if owner, ok := m.claims[id]; ok && owner != pubkey {
		return ErrTaken
	}
	if _, ok := m.live[id]; ok {
		return ErrTaken
	}
	m.claims[id] = pubkey
	m.live[id] = pubkey
	return nil
}

func TestAssignHonoursOnlyAFreePreferredIDForANewKey(t *testing.T) {
	l := newMemoryLedger()
	if id, existing, err := Assign(l, "A", "111111111"); err != nil || existing || id != "111111111" {
		t.Fatalf("free preferred id = %q existing=%v err=%v", id, existing, err)
	}
	if id, existing, err := Assign(l, "A", "222222222"); err != nil || !existing || id != "111111111" {
		t.Fatalf("known key = %q existing=%v err=%v", id, existing, err)
	}
	if id, _, err := Assign(l, "B", "111111111"); err != nil || id == "111111111" || !protocol.ValidDeviceID(id) {
		t.Fatalf("held id = %q err=%v", id, err)
	}
	delete(l.live, "111111111")
	if id, _, err := Assign(l, "C", "111111111"); err != nil || id == "111111111" {
		t.Fatalf("tombstoned id went to another key: %q err=%v", id, err)
	}
	if id, existing, err := Assign(l, "A", "111111111"); err != nil || existing || id != "111111111" {
		t.Fatalf("original key could not reclaim its id: %q existing=%v err=%v", id, existing, err)
	}
}

func TestNewShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		id, err := New()
		if err != nil {
			t.Fatal(err)
		}
		if !protocol.ValidDeviceID(id) || id[0] == '0' {
			t.Fatalf("id %q is not 9 digits without a leading 0", id)
		}
		seen[id] = true
	}
	if len(seen) < 190 {
		t.Fatalf("only %d unique ids out of 200", len(seen))
	}
}
