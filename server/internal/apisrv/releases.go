package apisrv

import (
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"rc-signal/internal/apidb"
	protocol "rcprotocol"
)

var (
	releasePlatforms = []string{protocol.PlatformMacOS}
	releaseArches    = []string{protocol.ArchARM64, protocol.ArchX86_64}
	releaseChannels  = []string{protocol.ChannelStable, protocol.ChannelBeta}
)

func oneOf(value string, allowed []string) bool {
	for _, a := range allowed {
		if value == a {
			return true
		}
	}
	return false
}

func (s *Server) latestRelease(w http.ResponseWriter, r *http.Request) {
	if !s.allow(w, r, limitReleaseLatest, s.clientIP(r)) {
		return
	}
	if !knownQuery(r, "platform", "arch", "channel") {
		s.badRequest(w, r, "unknown query parameter")
		return
	}
	q := r.URL.Query()
	track := apidb.ReleaseTrack{Platform: q.Get("platform"), Arch: q.Get("arch"), Channel: q.Get("channel")}
	if track.Channel == "" {
		track.Channel = protocol.ChannelStable
	}
	if problem := validTrack(track); problem != "" {
		s.badRequest(w, r, problem)
		return
	}
	release, err := s.opt.DB.LatestRelease(track)
	if errors.Is(err, apidb.ErrNotFound) {
		s.fail(w, r, http.StatusNotFound, protocol.APIErrNotFound, "no release on that track")
		return
	}
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age="+strconv.Itoa(protocol.ReleaseCacheSec))
	w.Header().Set("Vary", "Accept-Encoding")
	s.writeJSON(w, r, http.StatusOK, release)
}

func validTrack(t apidb.ReleaseTrack) string {
	switch {
	case !oneOf(t.Platform, releasePlatforms):
		return "'platform' must be one of " + strings.Join(releasePlatforms, ", ")
	case !oneOf(t.Arch, releaseArches):
		return "'arch' must be one of " + strings.Join(releaseArches, ", ")
	case !oneOf(t.Channel, releaseChannels):
		return "'channel' must be one of " + strings.Join(releaseChannels, ", ")
	}
	return ""
}

// TODO: remove at launch with the rest of API.md §6.3. Development identity provider only.
func (s *Server) devPublishRelease(w http.ResponseWriter, r *http.Request) {
	if s.opt.IdP.Name() != "dev" {
		s.notFound(w, r)
		return
	}
	if _, ok := s.userSession(w, r); !ok {
		return
	}
	s.publishRelease(w, r)
}

// publishRelease records WHAT to install. It is never the client's reason to trust a
// download: the app's own checks decide that (docs/SECURITY.md "Updates"). In production
// it is reached only through the loopback internal listener (API.md §6), so publishing
// adds no public surface.
func (s *Server) publishRelease(w http.ResponseWriter, r *http.Request) {
	body, ok := s.readBody(w, r)
	if !ok {
		return
	}
	var req protocol.DevReleaseRequest
	if !s.decode(w, r, body, &req) {
		return
	}
	if req.Channel == "" {
		req.Channel = protocol.ChannelStable
	}
	track := apidb.ReleaseTrack{Platform: req.Platform, Arch: req.Arch, Channel: req.Channel}
	problem := validTrack(track)
	if problem == "" {
		problem = validRelease(req)
	}
	if problem != "" {
		s.badRequest(w, r, problem)
		return
	}
	release := protocol.AppRelease{
		Version: req.Version, Build: req.Build, MinimumOS: req.MinimumOS, URL: req.URL,
		SHA256: strings.ToLower(req.SHA256), Size: req.Size, Notes: req.Notes,
		PublishedAt: s.nowMS(), Critical: req.Critical,
	}
	if err := s.opt.DB.PutRelease(track, release); err != nil {
		s.internalError(w, r, err)
		return
	}
	s.writeJSON(w, r, http.StatusCreated, release)
}

func validRelease(req protocol.DevReleaseRequest) string {
	switch {
	case !validDottedNumber(req.Version):
		return "'version' must be dot-separated numbers"
	case !validDottedNumber(req.Build):
		return "'build' must be dot-separated numbers"
	case !validDottedNumber(req.MinimumOS):
		return "'minimumOS' must be dot-separated numbers"
	case !validSHA256Hex(req.SHA256):
		return "'sha256' must be 64 hex characters"
	case req.Size <= 0:
		return "'size' must be positive"
	case len(req.Notes) > protocol.MaxReleaseNotesLen:
		return "'notes' is too long"
	case !validDownloadURL(req.URL):
		return "'url' must be https, or http on localhost"
	}
	return ""
}

func validDottedNumber(v string) bool {
	if v == "" || len(v) > 32 {
		return false
	}
	for _, part := range strings.Split(v, ".") {
		if part == "" || len(part) > 9 {
			return false
		}
		for _, c := range part {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

func validSHA256Hex(v string) bool {
	raw, err := hex.DecodeString(v)
	return err == nil && len(raw) == 32
}

func validDownloadURL(raw string) bool {
	if len(raw) > protocol.MaxReleaseURLLen {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		host := u.Hostname()
		return host == "localhost" || net.ParseIP(host).IsLoopback()
	}
	return false
}
