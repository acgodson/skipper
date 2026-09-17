// Package envx reads the environment defaults both server commands use.
package envx

import (
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
