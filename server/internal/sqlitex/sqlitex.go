// Package sqlitex opens the SQLite databases every server command uses, with one set of pragmas.
package sqlitex

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

// Open opens path with a single connection, WAL and foreign keys, then applies schema.
func Open(path, schema string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	for _, p := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA foreign_keys=ON",
	} {
		if _, err := db.Exec(p); err != nil {
			db.Close()
			return nil, fmt.Errorf("%s: %w", p, err)
		}
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

// SiblingPath names the file next to path with suffix before its extension: a.db, "-claims" -> a-claims.db.
func SiblingPath(path, suffix string) string {
	if path == ":memory:" {
		return path
	}
	ext := filepath.Ext(path)
	return strings.TrimSuffix(path, ext) + suffix + ext
}
