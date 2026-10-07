// Package turnwire encodes the few STUN/TURN messages needed to authenticate against a
// coturn server the way a WebRTC client does: Allocate, CreatePermission and Refresh with
// long-term credentials. Standard library only (RFC 5389 §15.4 fixes HMAC-SHA1 for
// MESSAGE-INTEGRITY and MD5 for the long-term key; neither is our choice).
package turnwire

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"net"
	"net/netip"
	"time"
)

const (
	MethodAllocate         uint16 = 0x003
	MethodRefresh          uint16 = 0x004
	MethodCreatePermission uint16 = 0x008
)

const (
	ClassRequest uint16 = 0x0000
	ClassSuccess uint16 = 0x0100
	ClassError   uint16 = 0x0110
)

const (
	AttrUsername         uint16 = 0x0006
	AttrMessageIntegrity uint16 = 0x0008
	AttrErrorCode        uint16 = 0x0009
	AttrLifetime         uint16 = 0x000D
	AttrXORPeerAddress   uint16 = 0x0012
	AttrRealm            uint16 = 0x0014
	AttrNonce            uint16 = 0x0015
	AttrXORRelayedAddr   uint16 = 0x0016
	AttrRequestedTranspt uint16 = 0x0019
	AttrXORMappedAddress uint16 = 0x0020
	AttrFingerprint      uint16 = 0x8028
)

const (
	magicCookie    uint32 = 0x2112A442
	fingerprintXOR uint32 = 0x5354554E
	headerLen             = 20
	attrHeaderLen         = 4
	transportUDP   byte   = 17
	familyIPv4     byte   = 0x01
	familyIPv6     byte   = 0x02
	maxMessageLen         = 1500
)

var ErrNotSTUN = errors.New("turnwire: not a STUN message")

type Attr struct {
	Type  uint16
	Value []byte
}

type Message struct {
	Type  uint16
	TxID  [12]byte
	Attrs []Attr
}

func MessageType(method, class uint16) uint16 {
	return ((method & 0x0F80) << 2) | ((method & 0x0070) << 1) | (method & 0x000F) | class
}

func (m *Message) Method() uint16 {
	return ((m.Type & 0x3E00) >> 2) | ((m.Type & 0x00E0) >> 1) | (m.Type & 0x000F)
}

func (m *Message) Class() uint16 { return m.Type & 0x0110 }

func (m *Message) Add(t uint16, v []byte) { m.Attrs = append(m.Attrs, Attr{Type: t, Value: v}) }

func (m *Message) AddString(t uint16, v string) { m.Add(t, []byte(v)) }

func (m *Message) AddUint32(t uint16, v uint32) {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	m.Add(t, b[:])
}

// AddRequestedTransport asks for a UDP relay; the three bytes after the protocol are RFFU.
func (m *Message) AddRequestedTransport() {
	m.Add(AttrRequestedTranspt, []byte{transportUDP, 0, 0, 0})
}

func (m *Message) AddXORAddress(t uint16, ap netip.AddrPort) {
	m.Add(t, xorAddrValue(ap, m.TxID))
}

func (m *Message) Get(t uint16) ([]byte, bool) {
	for _, a := range m.Attrs {
		if a.Type == t {
			return a.Value, true
		}
	}
	return nil, false
}

func (m *Message) GetString(t uint16) (string, bool) {
	v, ok := m.Get(t)
	return string(v), ok
}

func (m *Message) Lifetime() (uint32, bool) {
	v, ok := m.Get(AttrLifetime)
	if !ok || len(v) != 4 {
		return 0, false
	}
	return binary.BigEndian.Uint32(v), true
}

// ErrorCode returns the RFC 5389 §15.6 code (class*100+number) and its reason phrase.
func (m *Message) ErrorCode() (int, string, bool) {
	v, ok := m.Get(AttrErrorCode)
	if !ok || len(v) < 4 {
		return 0, "", false
	}
	return int(v[2]&0x07)*100 + int(v[3]), string(v[4:]), true
}

func (m *Message) XORAddress(t uint16) (netip.AddrPort, bool) {
	v, ok := m.Get(t)
	if !ok || len(v) < 8 {
		return netip.AddrPort{}, false
	}
	port := binary.BigEndian.Uint16(v[2:4]) ^ uint16(magicCookie>>16)
	var mask [16]byte
	binary.BigEndian.PutUint32(mask[0:], magicCookie)
	copy(mask[4:], m.TxID[:])
	switch {
	case v[1] == familyIPv4 && len(v) >= 8:
		var ip [4]byte
		for i := range ip {
			ip[i] = v[4+i] ^ mask[i]
		}
		return netip.AddrPortFrom(netip.AddrFrom4(ip), port), true
	case v[1] == familyIPv6 && len(v) >= 20:
		var ip [16]byte
		for i := range ip {
			ip[i] = v[4+i] ^ mask[i]
		}
		return netip.AddrPortFrom(netip.AddrFrom16(ip), port), true
	}
	return netip.AddrPort{}, false
}

func xorAddrValue(ap netip.AddrPort, txid [12]byte) []byte {
	var mask [16]byte
	binary.BigEndian.PutUint32(mask[0:], magicCookie)
	copy(mask[4:], txid[:])
	addr := ap.Addr().Unmap()
	raw := addr.AsSlice()
	family := familyIPv4
	if addr.Is6() {
		family = familyIPv6
	}
	out := make([]byte, 4+len(raw))
	out[1] = family
	binary.BigEndian.PutUint16(out[2:], ap.Port()^uint16(magicCookie>>16))
	for i := range raw {
		out[4+i] = raw[i] ^ mask[i]
	}
	return out
}

// LongTermKey is RFC 5389 §15.4's long-term credential key.
func LongTermKey(username, realm, password string) []byte {
	sum := md5.Sum([]byte(username + ":" + realm + ":" + password))
	return sum[:]
}

// Marshal serialises the message, appending MESSAGE-INTEGRITY when key is non-nil and
// always a FINGERPRINT. Each digest covers the message with the header length already
// raised to include the attribute being appended (RFC 5389 §15.4, §15.5).
func (m *Message) Marshal(key []byte) []byte {
	buf := make([]byte, headerLen, 256)
	binary.BigEndian.PutUint16(buf[0:], m.Type)
	binary.BigEndian.PutUint32(buf[4:], magicCookie)
	copy(buf[8:], m.TxID[:])
	for _, a := range m.Attrs {
		buf = appendAttr(buf, a.Type, a.Value)
	}
	if key != nil {
		setBodyLen(buf, len(buf)-headerLen+attrHeaderLen+sha1.Size)
		mac := hmac.New(sha1.New, key)
		mac.Write(buf)
		buf = appendAttr(buf, AttrMessageIntegrity, mac.Sum(nil))
	}
	setBodyLen(buf, len(buf)-headerLen+attrHeaderLen+4)
	var fp [4]byte
	binary.BigEndian.PutUint32(fp[:], crc32.ChecksumIEEE(buf)^fingerprintXOR)
	return appendAttr(buf, AttrFingerprint, fp[:])
}

func appendAttr(buf []byte, t uint16, v []byte) []byte {
	var h [attrHeaderLen]byte
	binary.BigEndian.PutUint16(h[0:], t)
	binary.BigEndian.PutUint16(h[2:], uint16(len(v)))
	buf = append(buf, h[:]...)
	buf = append(buf, v...)
	for pad := -len(v) & 3; pad > 0; pad-- {
		buf = append(buf, 0)
	}
	return buf
}

func setBodyLen(buf []byte, n int) { binary.BigEndian.PutUint16(buf[2:], uint16(n)) }

func Parse(raw []byte) (*Message, error) {
	if len(raw) < headerLen {
		return nil, ErrNotSTUN
	}
	if binary.BigEndian.Uint32(raw[4:]) != magicCookie {
		return nil, ErrNotSTUN
	}
	body := int(binary.BigEndian.Uint16(raw[2:]))
	if body+headerLen > len(raw) {
		return nil, fmt.Errorf("turnwire: body claims %d bytes, have %d", body, len(raw)-headerLen)
	}
	m := &Message{Type: binary.BigEndian.Uint16(raw[0:])}
	copy(m.TxID[:], raw[8:20])
	for p := headerLen; p+attrHeaderLen <= headerLen+body; {
		t := binary.BigEndian.Uint16(raw[p:])
		n := int(binary.BigEndian.Uint16(raw[p+2:]))
		p += attrHeaderLen
		if p+n > headerLen+body {
			return nil, errors.New("turnwire: attribute runs past the message body")
		}
		m.Add(t, append([]byte(nil), raw[p:p+n]...))
		p += n + (-n & 3)
	}
	return m, nil
}

// Conn is one STUN transaction endpoint. A TURN allocation belongs to the five-tuple, so a
// fresh Conn is a fresh allocation and a fresh nonce.
type Conn struct {
	c       net.Conn
	timeout time.Duration
}

func Dial(network, addr string, timeout time.Duration) (*Conn, error) {
	c, err := net.DialTimeout(network, addr, timeout)
	if err != nil {
		return nil, err
	}
	return &Conn{c: c, timeout: timeout}, nil
}

func (c *Conn) Close() error { return c.c.Close() }

func (c *Conn) LocalAddr() net.Addr { return c.c.LocalAddr() }

// NewRequest starts a request with a fresh transaction id.
func NewRequest(method uint16) (*Message, error) {
	m := &Message{Type: MessageType(method, ClassRequest)}
	if _, err := rand.Read(m.TxID[:]); err != nil {
		return nil, err
	}
	return m, nil
}

// Round sends a request and returns the response whose transaction id matches. UDP loses
// packets, so the request is retransmitted until the deadline rather than failing on the
// first silence.
func (c *Conn) Round(m *Message, key []byte) (*Message, error) {
	raw := m.Marshal(key)
	deadline := time.Now().Add(c.timeout)
	buf := make([]byte, maxMessageLen)
	var lastErr error
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		if _, err := c.c.Write(raw); err != nil {
			return nil, err
		}
		step := time.Duration(1<<attempt) * 250 * time.Millisecond
		if until := time.Until(deadline); step > until {
			step = until
		}
		if err := c.c.SetReadDeadline(time.Now().Add(step)); err != nil {
			return nil, err
		}
		for {
			n, err := c.c.Read(buf)
			if err != nil {
				lastErr = err
				break
			}
			in, perr := Parse(buf[:n])
			if perr != nil || in.TxID != m.TxID {
				continue
			}
			return in, nil
		}
	}
	if lastErr == nil {
		lastErr = errors.New("no response")
	}
	return nil, fmt.Errorf("turnwire: no answer to %#04x: %w", m.Type, lastErr)
}
