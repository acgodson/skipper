package protocol

import (
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
