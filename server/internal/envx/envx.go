// Package envx reads the environment defaults both server commands use.
package envx

import "os"

func Env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}
