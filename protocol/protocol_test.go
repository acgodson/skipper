package protocol

import (
	"bytes"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestTrimLabelCutsOnARuneBoundaryAndDropsControls(t *testing.T) {
	got := TrimLabel(strings.Repeat("é", 40))
	if !utf8.ValidString(got) || got != strings.Repeat("é", MaxLabelLen/2) {
		t.Fatalf("TrimLabel(80 bytes of é) = %q (%d bytes)", got, len(got))
	}
	if got := TrimLabel("  Studio\x00 Mac\x1b[31m \xff"); got != "Studio Mac[31m" {
		t.Fatalf("control characters and invalid UTF-8 survived: %q", got)
	}
	if got := TrimLabel(strings.Repeat("a", 63) + "中"); got != strings.Repeat("a", 63) {
		t.Fatalf("a 3-byte rune straddling the limit was split: %q", got)
	}
}

func TestByeReasonsAreAClosedSet(t *testing.T) {
	for _, r := range ByeReasons {
		if !ValidByeReason(r) {
			t.Fatalf("%q is listed but refused", r)
		}
	}
	for _, r := range []string{"", "user", "USER_ENDED", strings.Repeat("A", 70*1024), "declined\n"} {
		if ValidByeReason(r) {
			t.Fatalf("%.20q was accepted", r)
		}
	}
}

func TestTheSharedVectorsMatchThisBuild(t *testing.T) {
	raw, err := os.ReadFile("vectors/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Version           int      `json:"version"`
		ByeReasons        []string `json:"byeReasons"`
		InvalidByeReasons []string `json:"invalidByeReasons"`
		Cases             []struct {
			Name  string          `json:"name"`
			Frame json.RawMessage `json:"frame"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if file.Version != Version || !slices.Equal(file.ByeReasons, ByeReasons) || len(file.InvalidByeReasons) == 0 {
		t.Fatalf("vector file v%d reasons %v; regenerate with go run ./vectors", file.Version, file.ByeReasons)
	}
	for _, r := range file.InvalidByeReasons {
		if ValidByeReason(r) {
			t.Fatalf("invalid bye reason %q is accepted", r)
		}
	}
	for _, c := range file.Cases {
		if _, err := Decode(c.Frame); err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
	}
}

func TestValidSessionID(t *testing.T) {
	if !ValidSessionID("8c7f1a2b3c4d5e6f708192a3b4c5d6e7") {
		t.Fatal("a real session id was refused")
	}
	for _, bad := range []string{
		"", "8C7F1A2B3C4D5E6F708192A3B4C5D6E7", "8c7f1a2b3c4d5e6f708192a3b4c5d6e",
		"8c7f1a2b3c4d5e6f708192a3b4c5d6e7|x", "g" + strings.Repeat("0", 31),
	} {
		if ValidSessionID(bad) {
			t.Fatalf("%q was accepted", bad)
		}
	}
}

func TestRelayVectorsDecodeStrictlyAndReencodeExactly(t *testing.T) {
	raw, err := os.ReadFile("vectors/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Cases []struct {
			Name  string   `json:"name"`
			Type  string   `json:"type"`
			Frame Envelope `json:"frame"`
		} `json:"cases"`
		Relay struct {
			Accepted []struct {
				Name   string `json:"name"`
				Type   string `json:"type"`
				Input  string `json:"input"`
				Output string `json:"output"`
			} `json:"accepted"`
			Rejected []struct {
				Name  string `json:"name"`
				Type  string `json:"type"`
				Input string `json:"input"`
			} `json:"rejected"`
		} `json:"relay"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Relay.Accepted) == 0 || len(file.Relay.Rejected) < 30 {
		t.Fatalf("relay vectors look truncated: %d accepted, %d rejected", len(file.Relay.Accepted), len(file.Relay.Rejected))
	}
	for _, c := range file.Relay.Accepted {
		msg, err := DecodeRelay(c.Type, []byte(c.Input))
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		out, err := json.Marshal(msg)
		if err != nil || string(out) != string(c.Output) {
			t.Fatalf("%s: re-encoded %s, want %s", c.Name, out, c.Output)
		}
	}
	for _, c := range file.Relay.Rejected {
		if _, err := DecodeRelay(c.Type, []byte(c.Input)); err == nil {
			t.Fatalf("%s: accepted %.80q", c.Name, c.Input)
		}
	}
	relayed := 0
	for _, c := range file.Cases {
		if c.Type != TypeSDP && c.Type != TypeICE && c.Type != TypePake {
			continue
		}
		relayed++
		msg, err := DecodeRelay(c.Type, c.Frame.Payload)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		var want bytes.Buffer
		if err := json.Compact(&want, c.Frame.Payload); err != nil {
			t.Fatal(err)
		}
		if out, _ := json.Marshal(msg); string(out) != want.String() {
			t.Fatalf("%s: re-encoded %s, want %s", c.Name, out, c.Frame.Payload)
		}
	}
	if relayed < 8 {
		t.Fatalf("only %d relayed message cases", relayed)
	}
}

func TestICECandidateGrammar(t *testing.T) {
	for _, ok := range []string{
		"candidate:1 1 udp 2130706431 192.0.2.1 54321 typ host",
		"candidate:a+/Z 256 UDP 0 ::1 0 typ relay raddr 198.51.100.1 rport 3478",
		"candidate:1 1 tcp 1 3F1C6E0A-9B2D-4C5E-8F7A-1D2E3F4A5B6C.local 9 typ host tcptype passive",
	} {
		if !ValidICECandidate(ok) {
			t.Fatalf("refused %q", ok)
		}
	}
	for _, bad := range []string{
		"", "candidate:", "candidate:1 0 udp 1 192.0.2.1 1 typ host",
		"candidate:1 257 udp 1 192.0.2.1 1 typ host",
		"candidate:1 1 sctp 1 192.0.2.1 1 typ host",
		"candidate:1 1 udp 4294967296 192.0.2.1 1 typ host",
		"candidate:1 1 udp 1 192.0.2.1 65536 typ host",
		"candidate:1 1 udp 1 192.0.2.1 1 type host",
		"candidate:1 1 udp 1 fe80::1%en0 1 typ host",
		"candidate:1 1 udp 1 01.2.3.4 1 typ host",
		"candidate:1 1 udp 1 3f1c6e0a9b2d4c5e8f7a1d2e3f4a5b6c0000.local 1 typ host",
		"candidate:1 1 udp 1 192.0.2.1 1 typ host Generation 0",
		"candidate:1 1 udp 1 192.0.2.1 1 typ host ufrag a\tb",
		"candidate:" + strings.Repeat("a", 33) + " 1 udp 1 192.0.2.1 1 typ host",
		"candidate:1 1 udp 1 192.0.2.1 1 typ host" + strings.Repeat(" a b", MaxCandidateExtensions+1),
	} {
		if ValidICECandidate(bad) {
			t.Fatalf("accepted %q", bad)
		}
	}
}
