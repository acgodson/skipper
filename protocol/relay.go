// Relayed signaling messages (PROTOCOL.md §2.12, §2.13, §2.17). The server decodes each into its
// exact schema, validates it, and relays only its own re-encoding; client bytes are never forwarded.
package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strconv"
	"strings"
)

const (
	MaxPakePayloadBytes    = 4096
	MaxSDPBytes            = 64 * 1024
	MaxCandidateBytes      = 1024
	MaxCandidateExtensions = 16
	MaxFingerprintBytes    = 1024
	MaxPubkeyChars         = 256
	MaxSigChars            = 256
	MaxMACChars            = 128
	MaxSDPMidBytes         = 32
	MaxSDPMLineIndex       = 1<<31 - 1
	PakeStepFirst          = 1
	PakeStepLast           = 3
	SDPVersionPrefix       = "v=0"
	CandidatePrefix        = "candidate:"
)

// Before a session is metered the server relays at most this much of it.
const (
	MaxUnmeteredICEPerSide  = 64
	MaxUnmeteredSDPFromCtrl = 4
)

var SDPTypes = []string{"offer", "answer", "pranswer", "rollback"}

var CandidateTypes = []string{"host", "srflx", "prflx", "relay"}

type SDP struct {
	SessionID string `json:"sessionId"`
	SDPType   string `json:"sdpType"`
	SDP       string `json:"sdp"`
	Restart   bool   `json:"restart,omitempty"`
	FP        string `json:"fp,omitempty"`
	Pubkey    string `json:"pubkey,omitempty"`
	Sig       string `json:"sig,omitempty"`
	MAC       string `json:"mac,omitempty"`
}

// ICE.Candidate "" is end-of-candidates; SDPMLineIndex keeps an explicit 0.
type ICE struct {
	SessionID     string `json:"sessionId"`
	Candidate     string `json:"candidate"`
	SDPMid        string `json:"sdpMid,omitempty"`
	SDPMLineIndex *int   `json:"sdpMLineIndex,omitempty"`
}

// Pake.Payload is base64 of the opaque SPAKE2 message; the server never parses, stores or logs it.
type Pake struct {
	SessionID string `json:"sessionId"`
	Step      int    `json:"step"`
	Payload   string `json:"payload"`
}

type Relay interface {
	Session() string
	validate() error
}

func (m SDP) Session() string  { return m.SessionID }
func (m ICE) Session() string  { return m.SessionID }
func (m Pake) Session() string { return m.SessionID }

var ErrRelayPayload = errors.New("relay payload")

func relayErr(format string, args ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{ErrRelayPayload}, args...)...)
}

// DecodeRelay decodes a relayed payload into its exact schema and validates every field.
func DecodeRelay(msgType string, payload []byte) (Relay, error) {
	msg, err := decodeRelaySchema(msgType, payload)
	if err != nil {
		return nil, err
	}
	if !ValidSessionID(msg.Session()) {
		return nil, relayErr("sessionId must be 32 lowercase hex")
	}
	if err := msg.validate(); err != nil {
		return nil, err
	}
	return msg, nil
}

func decodeRelaySchema(msgType string, payload []byte) (Relay, error) {
	switch msgType {
	case TypeSDP:
		var m SDP
		err := UnmarshalStrict(payload, &m, "sessionId", "sdpType", "sdp")
		return m, err
	case TypeICE:
		var m ICE
		err := UnmarshalStrict(payload, &m, "sessionId", "candidate")
		return m, err
	case TypePake:
		var m Pake
		err := UnmarshalStrict(payload, &m, "sessionId", "step", "payload")
		return m, err
	}
	return nil, relayErr("%q is not a relayed type", msgType)
}

func (m SDP) validate() error {
	switch {
	case !oneOf(m.SDPType, SDPTypes):
		return relayErr("sdpType must be one of %v", SDPTypes)
	case len(m.SDP) > MaxSDPBytes:
		return relayErr("sdp exceeds %d bytes", MaxSDPBytes)
	case !strings.HasPrefix(m.SDP, SDPVersionPrefix) || strings.IndexByte(m.SDP, 0) >= 0:
		return relayErr("sdp must begin with %q and contain no NUL", SDPVersionPrefix)
	case len(m.FP) > MaxFingerprintBytes || !allBytes(m.FP, isFingerprintByte):
		return relayErr("fp is malformed")
	case len(m.Pubkey) > MaxPubkeyChars || !allBytes(m.Pubkey, isBase64Byte):
		return relayErr("pubkey is malformed")
	case len(m.Sig) > MaxSigChars || !allBytes(m.Sig, isBase64Byte):
		return relayErr("sig is malformed")
	case len(m.MAC) > MaxMACChars || !allBytes(m.MAC, isBase64Byte):
		return relayErr("mac is malformed")
	}
	return nil
}

func (m ICE) validate() error {
	switch {
	case m.Candidate != "" && !ValidICECandidate(m.Candidate):
		return relayErr("candidate is not an ICE candidate line")
	case len(m.SDPMid) > MaxSDPMidBytes || !allBytes(m.SDPMid, isMidByte):
		return relayErr("sdpMid is malformed")
	case m.SDPMLineIndex != nil && (*m.SDPMLineIndex < 0 || *m.SDPMLineIndex > MaxSDPMLineIndex):
		return relayErr("sdpMLineIndex is outside 0..%d", MaxSDPMLineIndex)
	}
	return nil
}

func (m Pake) validate() error {
	switch {
	case m.Step < PakeStepFirst || m.Step > PakeStepLast:
		return relayErr("step must be an integer %d..%d", PakeStepFirst, PakeStepLast)
	case len(m.Payload) > MaxPakePayloadBytes:
		return relayErr("payload exceeds %d base64 characters", MaxPakePayloadBytes)
	case !ValidPaddedBase64(m.Payload):
		return relayErr("payload must be non-empty padded standard base64")
	}
	return nil
}

// ValidICECandidate accepts exactly the §2.13 grammar: "candidate:" foundation SP component SP
// transport SP priority SP address SP port SP "typ" SP type, then up to 16 SP name SP value pairs.
func ValidICECandidate(line string) bool {
	rest, ok := strings.CutPrefix(line, CandidatePrefix)
	if !ok || len(line) > MaxCandidateBytes {
		return false
	}
	f := strings.Split(rest, " ")
	extra := len(f) - 8
	if extra < 0 || extra%2 != 0 || extra/2 > MaxCandidateExtensions {
		return false
	}
	if !boundedToken(f[0], 32, isIceChar) ||
		!decimalBetween(f[1], 3, 1, 256) ||
		!(strings.EqualFold(f[2], "udp") || strings.EqualFold(f[2], "tcp")) ||
		!decimalBetween(f[3], 10, 0, 1<<32-1) ||
		!validCandidateAddress(f[4]) ||
		!decimalBetween(f[5], 5, 0, 65535) ||
		f[6] != "typ" || !oneOf(f[7], CandidateTypes) {
		return false
	}
	for i := 8; i < len(f); i += 2 {
		if !boundedToken(f[i], 32, isExtNameByte) || !boundedToken(f[i+1], 256, isExtValueByte) {
			return false
		}
	}
	return true
}

// validCandidateAddress is an IP literal or an mDNS name "<uuid>.local".
func validCandidateAddress(s string) bool {
	if net.ParseIP(s) != nil {
		return true
	}
	name, ok := strings.CutSuffix(s, ".local")
	if !ok || len(name) != 36 {
		return false
	}
	for i := 0; i < len(name); i++ {
		dash := i == 8 || i == 13 || i == 18 || i == 23
		if dash != (name[i] == '-') || !dash && !isHexByte(name[i]) {
			return false
		}
	}
	return true
}

// ValidPaddedBase64 checks the shape of non-empty padded standard base64 without decoding it.
func ValidPaddedBase64(s string) bool {
	if s == "" || len(s)%4 != 0 {
		return false
	}
	body := strings.TrimRight(s, "=")
	if len(s)-len(body) > 2 {
		return false
	}
	return allBytes(body, isIceChar)
}

// UnmarshalStrict decodes a JSON object into the struct v points to. Every key must be one of
// the struct's exact json names, appear once and not be null; required keys must be present.
func UnmarshalStrict(raw []byte, v any, required ...string) error {
	names := jsonNames(reflect.TypeOf(v).Elem())
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return relayErr("payload must be a JSON object")
	}
	seen := map[string]bool{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return relayErr("malformed object")
		}
		key, _ := tok.(string)
		switch {
		case !names[key]:
			return relayErr("unknown key %q", key)
		case seen[key]:
			return relayErr("duplicate key %q", key)
		}
		seen[key] = true
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return relayErr("malformed value for %q", key)
		}
		if string(value) == "null" {
			return relayErr("%q must not be null", key)
		}
	}
	if _, err := dec.Token(); err != nil {
		return relayErr("malformed object")
	}
	if _, err := dec.Token(); err != io.EOF {
		return relayErr("trailing data after the object")
	}
	for _, key := range required {
		if !seen[key] {
			return relayErr("%q is required", key)
		}
	}
	strict := json.NewDecoder(bytes.NewReader(raw))
	strict.DisallowUnknownFields()
	if err := strict.Decode(v); err != nil {
		return relayErr("%v", err)
	}
	return nil
}

func jsonNames(t reflect.Type) map[string]bool {
	names := map[string]bool{}
	for i := 0; i < t.NumField(); i++ {
		name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		if name != "" && name != "-" {
			names[name] = true
		}
	}
	return names
}

func oneOf(s string, set []string) bool {
	for _, v := range set {
		if s == v {
			return true
		}
	}
	return false
}

func allBytes(s string, ok func(byte) bool) bool {
	for i := 0; i < len(s); i++ {
		if !ok(s[i]) {
			return false
		}
	}
	return true
}

func boundedToken(s string, max int, ok func(byte) bool) bool {
	return s != "" && len(s) <= max && allBytes(s, ok)
}

func decimalBetween(s string, digits int, min, max uint64) bool {
	if !boundedToken(s, digits, isDigitByte) {
		return false
	}
	n, err := strconv.ParseUint(s, 10, 64)
	return err == nil && n >= min && n <= max
}

func isDigitByte(c byte) bool { return c >= '0' && c <= '9' }

func isAlnumByte(c byte) bool {
	return isDigitByte(c) || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isHexByte(c byte) bool {
	return isDigitByte(c) || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

func isIceChar(c byte) bool { return isAlnumByte(c) || c == '+' || c == '/' }

func isBase64Byte(c byte) bool { return isIceChar(c) || c == '=' }

func isFingerprintByte(c byte) bool { return isAlnumByte(c) || strings.IndexByte(":- \n", c) >= 0 }

func isMidByte(c byte) bool { return isAlnumByte(c) || strings.IndexByte("_.+/-", c) >= 0 }

func isExtNameByte(c byte) bool { return isDigitByte(c) || c >= 'a' && c <= 'z' || c == '-' }

func isExtValueByte(c byte) bool { return isAlnumByte(c) || strings.IndexByte("+/=.:_-", c) >= 0 }
