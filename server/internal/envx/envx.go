// Package envx reads the environment defaults both server commands use.
package envx

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
)

func Env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func Int(key string, def int) int {
	v, err := strconv.Atoi(Env(key, strconv.Itoa(def)))
	if err != nil {
		return def
	}
	return v
}

// SecretFile reads a secret from a file, which is how a secret stays out of the
// process arguments every local user can read. An empty path is no secret, not
// an error; an empty file is an error, because it was meant to hold one.
func SecretFile(path, what string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("%s file: %w", what, err)
	}
	secret := strings.TrimSpace(string(raw))
	if secret == "" {
		return "", fmt.Errorf("%s file %s is empty", what, path)
	}
	return secret, nil
}

func LogLevel(name string) slog.Level {
	switch strings.ToLower(name) {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
