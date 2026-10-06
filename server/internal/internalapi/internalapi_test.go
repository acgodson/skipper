package internalapi

import (
	"bytes"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func discard() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func writeSecret(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "internal-token")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// The flag form is what ps shows to every local user, so the file and the
// environment must both win over it.
func TestTheInternalTokenPrefersTheFileAndThenTheEnvironment(t *testing.T) {
	file := writeSecret(t, "from-the-file\n")
	all := Secret{
		FilePath: file, FileFlagName: "internal-token-file",
		Env: "from-the-environment", EnvName: "RC_INTERNAL_TOKEN",
		Flag: "from-the-flag", FlagName: "internal-token",
	}
	got, err := ResolveSecret(all, discard())
	if err != nil || got != "from-the-file" {
		t.Fatalf("with all three: %q (%v), want the file's secret, trimmed", got, err)
	}

	noFile := all
	noFile.FilePath = ""
	if got, err := ResolveSecret(noFile, discard()); err != nil || got != "from-the-environment" {
		t.Fatalf("with no file: %q (%v), want the environment's secret", got, err)
	}

	flagOnly := noFile
	flagOnly.Env = ""
	var warnings bytes.Buffer
	log := slog.New(slog.NewTextHandler(&warnings, &slog.HandlerOptions{Level: slog.LevelWarn}))
	got, err = ResolveSecret(flagOnly, log)
	if err != nil || got != "from-the-flag" {
		t.Fatalf("with the flag only: %q (%v), want the flag to still work", got, err)
	}
	if !strings.Contains(warnings.String(), "-internal-token-file") {
		t.Fatalf("the deprecated flag form was not warned about: %q", warnings.String())
	}
	if strings.Contains(warnings.String(), "from-the-flag") {
		t.Fatalf("the warning printed the secret itself: %q", warnings.String())
	}

	none := flagOnly
	none.Flag = ""
	if got, err := ResolveSecret(none, discard()); err != nil || got != "" {
		t.Fatalf("with nothing given: %q (%v), want an empty secret and no error", got, err)
	}

	empty := Secret{FilePath: writeSecret(t, "  \n")}
	if _, err := ResolveSecret(empty, discard()); err == nil {
		t.Fatal("an empty token file was accepted")
	}
	missing := Secret{FilePath: filepath.Join(t.TempDir(), "absent")}
	if _, err := ResolveSecret(missing, discard()); err == nil {
		t.Fatal("a missing token file was accepted")
	}
}

func TestTheInternalListenerMustBeLoopbackUnlessOptedIn(t *testing.T) {
	for _, addr := range []string{"127.0.0.1:18081", "[::1]:18081", "localhost:18081"} {
		if err := CheckLoopback(addr, false); err != nil {
			t.Fatalf("%s was refused: %v", addr, err)
		}
	}
	for _, addr := range []string{":18081", "0.0.0.0:18081", "10.0.0.4:18081", "[::]:18081"} {
		if err := CheckLoopback(addr, false); err == nil {
			t.Fatalf("%s was accepted without the opt-in", addr)
		}
		if err := CheckLoopback(addr, true); err != nil {
			t.Fatalf("%s was refused despite the opt-in: %v", addr, err)
		}
	}
	if err := CheckLoopback("not-an-address", false); err == nil {
		t.Fatal("an unparseable internal listen address was accepted")
	}
}
