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
//
// Every transaction is BEGIN IMMEDIATE. The ledger's non-negative invariant reads a
// balance and then inserts against it, which a deferred BEGIN does not serialise: it
// takes its write lock lazily, so two such transactions can interleave their reads.
// Under SetMaxOpenConns(1) they cannot, but then the invariant rests on the size of
// the connection pool rather than on the isolation level, and the pool size is a
// reasonable thing for someone to change (review5 M13).
func Open(path, schema string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_txlock=immediate")
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
