package apisrv

import (
	"html/template"
	"net/http"
	"net/url"
	"strings"

	"rc-signal/internal/auth"
	"rc-signal/internal/idp"
	protocol "rcprotocol"
)

const linkStyle = `body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;margin:12vh auto;
max-width:30rem;color:#111;padding:0 1rem}
h1{font-size:22px}code{font-size:12px;color:#555;word-break:break-all}
input{font-size:16px;padding:.5rem;width:100%;box-sizing:border-box}
button{font-size:16px;padding:.6rem 1.2rem;margin-top:1rem}
p.note{color:#777;font-size:13px}`

var linkTemplate = template.Must(template.New("link").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>Link this Mac &middot; SkipperDesk</title>
<style>` + linkStyle + `</style></head><body>
<h1>Link this Mac</h1>
{{if .Cognito}}
<p>TODO: the SkipperDesk website at <code>{{.WebBase}}</code> signs the user in with Cognito
here and then calls <code>POST /v1/auth/link</code> with its user session. That page is
Phase 5 web work.</p>
{{else}}
<p>Local development sign-in. Enter the address this Mac should be linked to; the
account is created if it does not exist yet.</p>
<p><code>device={{.DeviceKey}}</code></p>
<form method="post" action="/link">
<input type="hidden" name="nonce" value="{{.Nonce}}">
<input type="hidden" name="device" value="{{.Pubkey}}">
<input type="hidden" name="platform" value="{{.Platform}}">
<input type="email" name="email" placeholder="you@example.com" value="{{.Email}}" required autofocus>
<button type="submit">Sign in and link</button>
</form>
{{if .Error}}<p class="note">{{.Error}}</p>{{end}}
<p class="note">The code is valid for {{.Lifetime}} seconds and can be used once.</p>
{{end}}
</body></html>`))

var handoffTemplate = template.Must(template.New("handoff").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>Linking &middot; SkipperDesk</title>
<style>` + linkStyle + `</style></head><body>
<h1>Handing this Mac back to the app</h1>
<p>Signed in as {{.Email}}.</p>
<p><a href="{{.Handoff}}">Open SkipperDesk</a> if nothing happens.</p>
<script>location.replace({{.Handoff}});</script>
</body></html>`))

type linkPageData struct {
	Cognito   bool
	WebBase   string
	Handoff   template.URL
	Nonce     string
	Pubkey    string
	DeviceKey string
	Platform  string
	Email     string
	Error     string
	Lifetime  int
}

func (s *Server) renderLink(w http.ResponseWriter, status int, data linkPageData) {
	data.Cognito = s.opt.IdP.Name() != "dev"
	data.Lifetime = protocol.LinkCodeTTLSec
	data.WebBase = s.opt.WebBaseURL
	if len(data.Pubkey) > 24 {
		data.DeviceKey = data.Pubkey[:24] + "…"
	} else {
		data.DeviceKey = data.Pubkey
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_ = linkTemplate.Execute(w, data)
}

func (s *Server) linkPage(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	nonce := query.Get("nonce")
	pubkey := query.Get("device")
	if s.opt.IdP.Name() == "dev" && (nonce == "" || pubkey == "") {
		s.renderLink(w, http.StatusBadRequest, linkPageData{
			Error: "This page needs the nonce and device key the app supplies."})
		return
	}
	s.renderLink(w, http.StatusOK, linkPageData{
		Nonce: nonce, Pubkey: pubkey, Platform: platformOrDefault(query.Get("platform"))})
}

func platformOrDefault(platform string) string {
	if platform == "" {
		return protocol.PlatformMacOS
	}
	return platform
}

// linkSubmit is the dev stand-in for the website: it mints a user session from
// the typed address and runs the §1.2 body with it.
func (s *Server) linkSubmit(w http.ResponseWriter, r *http.Request) {
	if s.opt.IdP.Name() != "dev" {
		s.renderLink(w, http.StatusNotFound, linkPageData{})
		return
	}
	if err := r.ParseForm(); err != nil {
		s.renderLink(w, http.StatusBadRequest, linkPageData{Error: "That form could not be read."})
		return
	}
	data := linkPageData{
		Nonce:    r.PostFormValue("nonce"),
		Pubkey:   r.PostFormValue("device"),
		Platform: platformOrDefault(r.PostFormValue("platform")),
		Email:    strings.TrimSpace(r.PostFormValue("email")),
	}
	session, err := idp.Dev{}.UserSession(r.Context(), "dev:"+data.Email)
	if err != nil {
		data.Error = "That does not look like an email address."
		s.renderLink(w, http.StatusBadRequest, data)
		return
	}
	if _, err := auth.ParsePubkey(data.Pubkey); err != nil || data.Nonce == "" {
		data.Error = "The app did not supply a usable device key."
		s.renderLink(w, http.StatusBadRequest, data)
		return
	}
	account, err := s.opt.DB.EnsureAccount(session.AccountID, session.Email, s.now())
	if err != nil {
		data.Error = "The account could not be created."
		s.renderLink(w, http.StatusInternalServerError, data)
		return
	}
	answer, conflict, err := s.mintLinkCode(account, protocol.LinkRequest{
		Nonce: data.Nonce, Pubkey: data.Pubkey, Platform: data.Platform, Label: r.PostFormValue("label"),
	})
	if err != nil || conflict != "" {
		data.Error = "That device is linked to another account; unlink it there first."
		s.renderLink(w, http.StatusConflict, data)
		return
	}
	target := callbackScheme + "?code=" + url.QueryEscape(answer.Code)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_ = handoffTemplate.Execute(w, linkPageData{Handoff: template.URL(target), Email: session.Email})
}
