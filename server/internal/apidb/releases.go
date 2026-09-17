package apidb

import (
	"database/sql"
	"errors"

	protocol "rcprotocol"
)

type ReleaseTrack struct {
	Platform string
	Arch     string
	Channel  string
}

func (d *DB) PutRelease(track ReleaseTrack, r protocol.AppRelease) error {
	_, err := d.db.Exec(`INSERT INTO releases
		(platform, arch, channel, build, version, minimum_os, url, sha256, size, notes, critical, published_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(platform, arch, channel, build) DO UPDATE SET
		version=excluded.version, minimum_os=excluded.minimum_os, url=excluded.url,
		sha256=excluded.sha256, size=excluded.size, notes=excluded.notes,
		critical=excluded.critical, published_at=excluded.published_at`,
		track.Platform, track.Arch, track.Channel, r.Build, r.Version, r.MinimumOS, r.URL,
		r.SHA256, r.Size, r.Notes, boolInt(r.Critical), r.PublishedAt)
	return err
}

// LatestRelease is the most recently published build on the track. Ordering by
// publication, not by build number, is what lets a bad release be pulled by
// republishing the previous one; clients still refuse to downgrade.
func (d *DB) LatestRelease(track ReleaseTrack) (*protocol.AppRelease, error) {
	var r protocol.AppRelease
	var critical int
	err := d.db.QueryRow(`SELECT version, build, minimum_os, url, sha256, size, notes, critical, published_at
		FROM releases WHERE platform=? AND arch=? AND channel=?
		ORDER BY published_at DESC, rowid DESC LIMIT 1`,
		track.Platform, track.Arch, track.Channel).
		Scan(&r.Version, &r.Build, &r.MinimumOS, &r.URL, &r.SHA256, &r.Size, &r.Notes, &critical, &r.PublishedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	r.Critical = critical != 0
	return &r, nil
}
