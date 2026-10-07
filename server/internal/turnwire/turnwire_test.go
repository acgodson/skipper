package turnwire

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"net/netip"
	"testing"
)

// The message types RFC 5766 §13 lists for Allocate pin the class/method packing, so a
// wrong bit layout cannot pass unnoticed.
func TestMessageTypePacking(t *testing.T) {
	cases := []struct {
		method, class, want uint16
	}{
		{MethodAllocate, ClassRequest, 0x0003},
		{MethodAllocate, ClassSuccess, 0x0103},
		{MethodAllocate, ClassError, 0x0113},
		{MethodRefresh, ClassRequest, 0x0004},
		{MethodCreatePermission, ClassRequest, 0x0008},
		{MethodCreatePermission, ClassError, 0x0118},
	}
	for _, c := range cases {
		got := MessageType(c.method, c.class)
		if got != c.want {
			t.Errorf("MessageType(%#03x, %#04x) = %#04x, want %#04x", c.method, c.class, got, c.want)
		}
		m := &Message{Type: got}
		if m.Method() != c.method || m.Class() != c.class {
			t.Errorf("%#04x round-trips to method %#03x class %#04x", got, m.Method(), m.Class())
		}
	}
}

// 192.0.2.1:32853 XOR the magic cookie is e1:12:a6:43 on port 0xa147; the arithmetic is
// stated here rather than recomputed, so an endianness slip fails.
func TestXORAddressIsCookieXORed(t *testing.T) {
	m := &Message{Type: MessageType(MethodCreatePermission, ClassRequest)}
	ap := netip.MustParseAddrPort("192.0.2.1:32853")
	m.AddXORAddress(AttrXORPeerAddress, ap)
	v, ok := m.Get(AttrXORPeerAddress)
	if !ok {
		t.Fatal("no XOR-PEER-ADDRESS")
	}
	want := []byte{0x00, familyIPv4, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43}
	if !bytes.Equal(v, want) {
		t.Fatalf("encoded %x, want %x", v, want)
	}
	back, ok := m.XORAddress(AttrXORPeerAddress)
	if !ok || back != ap {
		t.Fatalf("decoded %v (ok=%v), want %v", back, ok, ap)
	}
}

func TestMarshalParseRoundTripWithOddLengths(t *testing.T) {
	req, err := NewRequest(MethodAllocate)
	if err != nil {
		t.Fatal(err)
	}
	req.AddRequestedTransport()
	req.AddString(AttrUsername, "1760000000:deadbeef")
	req.AddString(AttrRealm, "turn.example")
	req.AddString(AttrNonce, "abc")
	req.AddUint32(AttrLifetime, 600)
	raw := req.Marshal(LongTermKey("u", "r", "p"))

	if got := int(binary.BigEndian.Uint16(raw[2:])); got != len(raw)-headerLen {
		t.Fatalf("header length %d, message body is %d", got, len(raw)-headerLen)
	}
	if len(raw)%4 != 0 {
		t.Fatalf("message is %d bytes, not a multiple of 4", len(raw))
	}

	got, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != req.Type || got.TxID != req.TxID {
		t.Fatalf("type/txid changed: %#04x %x", got.Type, got.TxID)
	}
	for _, want := range []struct {
		attr uint16
		val  string
	}{
		{AttrUsername, "1760000000:deadbeef"},
		{AttrRealm, "turn.example"},
		{AttrNonce, "abc"},
	} {
		if v, ok := got.GetString(want.attr); !ok || v != want.val {
			t.Errorf("attribute %#04x = %q (ok=%v), want %q", want.attr, v, ok, want.val)
		}
	}
	if life, ok := got.Lifetime(); !ok || life != 600 {
		t.Errorf("LIFETIME = %d (ok=%v), want 600", life, ok)
	}
	if mi, ok := got.Get(AttrMessageIntegrity); !ok || len(mi) != 20 {
		t.Errorf("MESSAGE-INTEGRITY is %d bytes (ok=%v), want 20", len(mi), ok)
	}
}

// MESSAGE-INTEGRITY and FINGERPRINT are each computed over the message with the header
// length already raised to cover the attribute being appended. Recomputing the CRC the way
// a receiver does is the only way to catch a length that was adjusted at the wrong moment.
func TestFingerprintVerifiesAsAReceiverWouldCheckIt(t *testing.T) {
	req, err := NewRequest(MethodAllocate)
	if err != nil {
		t.Fatal(err)
	}
	req.AddRequestedTransport()
	req.AddString(AttrNonce, "nonce")
	raw := req.Marshal(LongTermKey("u", "r", "p"))

	fpStart := len(raw) - (attrHeaderLen + 4)
	if binary.BigEndian.Uint16(raw[fpStart:]) != AttrFingerprint {
		t.Fatal("FINGERPRINT is not the last attribute")
	}
	prefix := append([]byte(nil), raw[:fpStart]...)
	binary.BigEndian.PutUint16(prefix[2:], uint16(fpStart-headerLen+attrHeaderLen+4))
	want := crc32.ChecksumIEEE(prefix) ^ fingerprintXOR
	if got := binary.BigEndian.Uint32(raw[fpStart+attrHeaderLen:]); got != want {
		t.Fatalf("FINGERPRINT %#08x, recomputed %#08x", got, want)
	}

	miStart := fpStart - (attrHeaderLen + 20)
	if binary.BigEndian.Uint16(raw[miStart:]) != AttrMessageIntegrity {
		t.Fatal("MESSAGE-INTEGRITY does not sit immediately before FINGERPRINT")
	}
}

func TestErrorCodeParsesClassAndNumber(t *testing.T) {
	m := &Message{Type: MessageType(MethodAllocate, ClassError)}
	m.Add(AttrErrorCode, append([]byte{0, 0, 4, 1}, "Unauthorized"...))
	code, reason, ok := m.ErrorCode()
	if !ok || code != 401 || reason != "Unauthorized" {
		t.Fatalf("got %d %q (ok=%v), want 401 Unauthorized", code, reason, ok)
	}
	m.Attrs = nil
	m.Add(AttrErrorCode, append([]byte{0, 0, 4, 3}, "Forbidden IP"...))
	if code, _, _ := m.ErrorCode(); code != 403 {
		t.Fatalf("got %d, want 403", code)
	}
}

func TestParseRejectsNonSTUN(t *testing.T) {
	for _, raw := range [][]byte{
		nil,
		make([]byte, 19),
		append(make([]byte, 4), make([]byte, 16)...),
	} {
		if _, err := Parse(raw); err == nil {
			t.Errorf("Parse(%d bytes of junk) returned no error", len(raw))
		}
	}
}
