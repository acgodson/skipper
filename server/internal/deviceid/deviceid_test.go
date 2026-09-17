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
	if _, ok := m.claims[id]; ok {
		return ErrTaken
	}
	if _, ok := m.live[id]; ok {
		return ErrTaken
	}
	m.claims[id] = pubkey
	m.live[id] = pubkey
	return nil
}

func (m *memoryLedger) Restore(id, pubkey string) (bool, error) {
	owner, held := m.live[id]
	if held && owner == pubkey {
		return false, nil
	}
	m.claims[id] = pubkey
	m.live[id] = pubkey
	return held, nil
}

func TestWithoutACertificateANewKeyAlwaysGetsAFreshID(t *testing.T) {
	l := newMemoryLedger()
	first, err := Assign(l, "A", "")
	if err != nil || first.Existing || !protocol.ValidDeviceID(first.ID) {
		t.Fatalf("first key = %+v err=%v", first, err)
	}
	again, err := Assign(l, "A", "")
	if err != nil || !again.Existing || again.ID != first.ID {
		t.Fatalf("known key = %+v err=%v", again, err)
	}
	delete(l.live, first.ID)
	other, err := Assign(l, "B", "")
	if err != nil || other.ID == first.ID {
		t.Fatalf("a tombstoned id was reissued: %+v err=%v", other, err)
	}
}

func TestACertifiedIDIsRestoredOverASquatter(t *testing.T) {
	l := newMemoryLedger()
	l.live["111111111"] = "squatter"
	got, err := Assign(l, "owner", "111111111")
	if err != nil || got.ID != "111111111" || got.Existing || !got.Displaced {
		t.Fatalf("restore = %+v err=%v", got, err)
	}
	if l.live["111111111"] != "owner" {
		t.Fatalf("the id still belongs to %q", l.live["111111111"])
	}
	free, err := Assign(l, "other", "222222222")
	if err != nil || free.ID != "222222222" || free.Displaced {
		t.Fatalf("restore of a free id = %+v err=%v", free, err)
	}
	kept, err := Assign(l, "owner", "333333333")
	if err != nil || !kept.Existing || kept.ID != "111111111" {
		t.Fatalf("a key that holds an id keeps it = %+v err=%v", kept, err)
	}
	if _, err := Assign(l, "x", "12ab"); err == nil {
		t.Fatal("a malformed certified id was accepted")
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
