// turnprobe authenticates against a real coturn with credentials minted exactly as
// rc-signal mints them (internal/auth.TurnCreds), and asserts what must and must not work:
// a good credential allocates, a tampered or expired one does not, a public peer is
// permitted and a private one is refused. It prints no secret — usernames are public, the
// credential half is only ever shown as a fingerprint.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/envx"
	"rc-signal/internal/turnwire"

	"rcprotocol"
)

const (
	codeUnauthorized = 401
	codeForbidden    = 403
	codeStaleNonce   = 438
)

type probe struct {
	addr      string
	network   string
	realm     string
	secret    string
	sessionID string
	timeout   time.Duration
	failed    int
	checks    int
}

func main() {
	var (
		addr       = flag.String("addr", "turn.skipperdesk.app:3478", "coturn host:port")
		network    = flag.String("network", "udp", "udp or tcp")
		realm      = flag.String("realm", "turn.skipperdesk.app", "coturn realm")
		secretFile = flag.String("secret-file", "", "file holding the coturn static-auth-secret")
		sessionID  = flag.String("session", "", "32 hex characters; a random one if empty")
		ttl        = flag.Duration("ttl", 0, "credential lifetime; the protocol's own if zero")
		publicPeer = flag.String("public-peer", "1.1.1.1:9", "a public peer that must be permitted")
		denyPeers  = flag.String("denied-peers", "169.254.169.254:80,10.0.0.1:9", "peers that must be refused")
		timeout    = flag.Duration("timeout", 8*time.Second, "per-transaction budget")
		expectExp  = flag.String("expect-expired", "", "username of an earlier credential that must now be refused")
		printICE   = flag.Bool("print-ice-servers", false, "print the ice_servers push for the session, credential redacted")
		turnURLs   = flag.String("turn-urls", "", "comma-separated TURN urls for -print-ice-servers")
		stunURLs   = flag.String("stun-urls", "", "comma-separated STUN urls for -print-ice-servers")
	)
	flag.Parse()

	secret, err := envx.SecretFile(*secretFile, "TURN secret")
	if err != nil {
		die(err)
	}
	if secret == "" {
		die(errors.New("-secret-file is required"))
	}
	sid := *sessionID
	if sid == "" {
		sid, err = randomSessionID()
		if err != nil {
			die(err)
		}
	}
	life := *ttl
	if life == 0 {
		life = protocol.TurnCredTTLSec * time.Second
	}

	p := &probe{addr: *addr, network: *network, realm: *realm, secret: secret,
		sessionID: sid, timeout: *timeout}

	fmt.Printf("coturn        %s/%s realm=%s\n", p.addr, p.network, p.realm)
	fmt.Printf("secret        %d bytes, fp=%s\n", len(secret), fingerprint(secret))
	fmt.Printf("session       %s\n", sid)
	fmt.Printf("credential    lifetime %s (protocol.TurnCredTTLSec=%ds)\n",
		life, protocol.TurnCredTTLSec)
	fmt.Println()

	if *expectExp != "" {
		p.expiredIsRefused(*expectExp)
		p.report()
		return
	}

	user, cred, expiresAt := auth.TurnCreds(secret, sid, time.Now(), life)
	fmt.Printf("minted        username=%s expiresAt=%s credential-fp=%s\n",
		user, expiresAt.UTC().Format(time.RFC3339), fingerprint(cred))
	fmt.Println()

	if *printICE {
		p.printICEServers(*turnURLs, *stunURLs, user, cred, expiresAt)
	}

	relayed := p.goodCredentialAllocates(user, cred, *publicPeer, splitList(*denyPeers))
	p.tamperedCredentialIsRefused(user, cred)
	p.unknownSessionIsRefused(sid, life)
	p.pastDatedCredentialIsRefused(sid)

	if relayed.IsValid() {
		fmt.Printf("\nrelayed address for the good allocation: %s\n", relayed)
	}
	fmt.Printf("\nreuse this username after %s to prove expiry:\n  %s\n", life, user)
	p.report()
}

// goodCredentialAllocates is the positive case and the open-relay check in one allocation:
// a credential that coturn accepts, a public peer it permits, and the private peers it must
// refuse on that same already-authenticated allocation.
func (p *probe) goodCredentialAllocates(user, cred, publicPeer string, denied []string) netip.AddrPort {
	c, key, nonce, err := p.authenticate(user, cred)
	if err != nil {
		p.fail("a valid credential allocates", err.Error())
		return netip.AddrPort{}
	}
	defer c.Close()

	req, err := turnwire.NewRequest(turnwire.MethodAllocate)
	if err != nil {
		p.fail("a valid credential allocates", err.Error())
		return netip.AddrPort{}
	}
	req.AddRequestedTransport()
	req.AddString(turnwire.AttrUsername, user)
	req.AddString(turnwire.AttrRealm, p.realm)
	req.AddString(turnwire.AttrNonce, nonce)
	res, err := c.Round(req, key)
	if err != nil {
		p.fail("a valid credential allocates", err.Error())
		return netip.AddrPort{}
	}
	if res.Class() != turnwire.ClassSuccess {
		p.fail("a valid credential allocates", describe(res))
		return netip.AddrPort{}
	}
	relayed, _ := res.XORAddress(turnwire.AttrXORRelayedAddr)
	lifetime, _ := res.Lifetime()
	p.pass("a valid credential allocates",
		fmt.Sprintf("relayed=%s coturn LIFETIME=%ds", relayed, lifetime))

	p.permission(c, key, user, nonce, publicPeer, turnwire.ClassSuccess, 0,
		"a public peer is permitted")
	for _, peer := range denied {
		p.permission(c, key, user, nonce, peer, turnwire.ClassError, codeForbidden,
			"the relay refuses the private peer "+peer)
	}

	refresh, err := turnwire.NewRequest(turnwire.MethodRefresh)
	if err == nil {
		refresh.AddUint32(turnwire.AttrLifetime, 0)
		refresh.AddString(turnwire.AttrUsername, user)
		refresh.AddString(turnwire.AttrRealm, p.realm)
		refresh.AddString(turnwire.AttrNonce, nonce)
		if _, err := c.Round(refresh, key); err == nil {
			fmt.Println("        released the allocation (Refresh lifetime=0)")
		}
	}
	return relayed
}

func (p *probe) permission(c *turnwire.Conn, key []byte, user, nonce, peer string,
	wantClass uint16, wantCode int, what string) {
	ap, err := netip.ParseAddrPort(peer)
	if err != nil {
		p.fail(what, err.Error())
		return
	}
	req, err := turnwire.NewRequest(turnwire.MethodCreatePermission)
	if err != nil {
		p.fail(what, err.Error())
		return
	}
	req.AddXORAddress(turnwire.AttrXORPeerAddress, ap)
	req.AddString(turnwire.AttrUsername, user)
	req.AddString(turnwire.AttrRealm, p.realm)
	req.AddString(turnwire.AttrNonce, nonce)
	res, err := c.Round(req, key)
	if err != nil {
		p.fail(what, err.Error())
		return
	}
	if res.Class() != wantClass {
		p.fail(what, "got "+describe(res))
		return
	}
	if wantCode != 0 {
		code, _, _ := res.ErrorCode()
		if code != wantCode {
			p.fail(what, fmt.Sprintf("wanted %d, got %s", wantCode, describe(res)))
			return
		}
	}
	p.pass(what, describe(res))
}

func (p *probe) tamperedCredentialIsRefused(user, cred string) {
	p.allocateMustFail("a tampered credential is refused", user, flipLast(cred))
}

// unknownSessionIsRefused proves the credential names one session: the same expiry with
// another session id is a different HMAC and must not authenticate.
func (p *probe) unknownSessionIsRefused(sid string, life time.Duration) {
	other := strings.Repeat("a", 32)
	if other == sid {
		other = strings.Repeat("b", 32)
	}
	now := time.Now()
	_, otherCred, _ := auth.TurnCreds(p.secret, other, now, life)
	user, _, _ := auth.TurnCreds(p.secret, sid, now, life)
	p.allocateMustFail("another session's credential is refused for this username", user, otherCred)
}

// pastDatedCredentialIsRefused mints the same credential with an expiry already behind us.
// It is the expiry rule under test, not the clock, so it answers in one round trip.
func (p *probe) pastDatedCredentialIsRefused(sid string) {
	user, cred, _ := auth.TurnCreds(p.secret, sid, time.Now().Add(-time.Hour), time.Minute)
	p.allocateMustFail("a past-dated credential is refused ("+user+")", user, cred)
}

// expiredIsRefused re-presents a username minted in an earlier run, whose own expiry has
// since passed, with the credential re-derived from the secret. Nothing but time changed.
func (p *probe) expiredIsRefused(user string) {
	ts, _, ok := strings.Cut(user, ":")
	if !ok {
		p.fail("the expired credential is refused", "username is not <expiry>:<sessionId>")
		return
	}
	unix, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		p.fail("the expired credential is refused", "username expiry is not a unix time")
		return
	}
	age := time.Since(time.Unix(unix, 0))
	fmt.Printf("re-presenting  %s, whose expiry passed %s ago\n\n", user, age.Round(time.Second))
	if age < 0 {
		p.fail("the expired credential is refused",
			fmt.Sprintf("this credential is still valid for %s; wait longer", -age))
		return
	}
	cred := auth.TurnCredential(p.secret, user)
	p.allocateMustFail("the expired credential is refused", user, cred)
}

func (p *probe) allocateMustFail(what, user, cred string) {
	c, key, nonce, err := p.authenticate(user, cred)
	if err != nil {
		p.fail(what, err.Error())
		return
	}
	defer c.Close()
	req, err := turnwire.NewRequest(turnwire.MethodAllocate)
	if err != nil {
		p.fail(what, err.Error())
		return
	}
	req.AddRequestedTransport()
	req.AddString(turnwire.AttrUsername, user)
	req.AddString(turnwire.AttrRealm, p.realm)
	req.AddString(turnwire.AttrNonce, nonce)
	res, err := c.Round(req, key)
	if err != nil {
		p.fail(what, err.Error())
		return
	}
	code, _, _ := res.ErrorCode()
	if res.Class() == turnwire.ClassSuccess {
		p.fail(what, "coturn ALLOCATED — the credential was accepted")
		return
	}
	if code != codeUnauthorized && code != codeForbidden && code != codeStaleNonce {
		p.fail(what, "refused, but with an unexpected "+describe(res))
		return
	}
	p.pass(what, describe(res))
}

// authenticate performs the unauthenticated Allocate that harvests REALM and NONCE, then
// returns a connection ready for the authenticated retry on the same five-tuple.
func (p *probe) authenticate(user, cred string) (*turnwire.Conn, []byte, string, error) {
	c, err := turnwire.Dial(p.network, p.addr, p.timeout)
	if err != nil {
		return nil, nil, "", err
	}
	req, err := turnwire.NewRequest(turnwire.MethodAllocate)
	if err != nil {
		c.Close()
		return nil, nil, "", err
	}
	req.AddRequestedTransport()
	res, err := c.Round(req, nil)
	if err != nil {
		c.Close()
		return nil, nil, "", err
	}
	code, _, _ := res.ErrorCode()
	if code != codeUnauthorized {
		c.Close()
		return nil, nil, "", fmt.Errorf("an unauthenticated Allocate should be 401, got %s", describe(res))
	}
	nonce, okN := res.GetString(turnwire.AttrNonce)
	realm, okR := res.GetString(turnwire.AttrRealm)
	if !okN || !okR {
		c.Close()
		return nil, nil, "", errors.New("the 401 carried no REALM or NONCE")
	}
	if realm != p.realm {
		c.Close()
		return nil, nil, "", fmt.Errorf("coturn's realm is %q, not %q", realm, p.realm)
	}
	return c, turnwire.LongTermKey(user, realm, cred), nonce, nil
}

func (p *probe) printICEServers(turnURLs, stunURLs, user, cred string, expiresAt time.Time) {
	var servers []protocol.ICEServer
	if stun := splitList(stunURLs); len(stun) > 0 {
		servers = append(servers, protocol.ICEServer{URLs: stun})
	}
	if turn := splitList(turnURLs); len(turn) > 0 {
		servers = append(servers, protocol.ICEServer{URLs: turn, Username: user,
			Credential: cred, ExpiresAt: expiresAt.UnixMilli()})
	}
	push := protocol.ICEServers{SessionID: p.sessionID, ICEServers: servers}
	raw, err := json.MarshalIndent(push, "", "  ")
	if err != nil {
		die(err)
	}
	out := strings.ReplaceAll(string(raw), `"`+cred+`"`,
		`"<redacted, fp=`+fingerprint(cred)+`>"`)
	fmt.Println("ice_servers push (PROTOCOL.md §2.18), credential redacted:")
	fmt.Println(out)
	fmt.Println()
}

func (p *probe) pass(what, detail string) {
	p.checks++
	fmt.Printf("PASS  %s\n        %s\n", what, detail)
}

func (p *probe) fail(what, detail string) {
	p.checks++
	p.failed++
	fmt.Printf("FAIL  %s\n        %s\n", what, detail)
}

func (p *probe) report() {
	fmt.Println()
	if p.failed == 0 {
		fmt.Printf("TURN PROBE PASSED — %d checks\n", p.checks)
		return
	}
	fmt.Fprintf(os.Stderr, "TURN PROBE FAILED — %d of %d checks\n", p.failed, p.checks)
	os.Exit(1)
}

func describe(m *turnwire.Message) string {
	if code, reason, ok := m.ErrorCode(); ok {
		return fmt.Sprintf("%d %s", code, reason)
	}
	if m.Class() == turnwire.ClassSuccess {
		return fmt.Sprintf("success response to method %#03x", m.Method())
	}
	return fmt.Sprintf("response %#04x with no ERROR-CODE", m.Type)
}

func fingerprint(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])[:16]
}

// flipLast changes one base64 character of the credential, so the HMAC no longer matches
// while the username and every other field stay exactly as coturn expects them.
func flipLast(cred string) string {
	if cred == "" {
		return "x"
	}
	last := cred[len(cred)-1]
	swap := byte('A')
	if last == 'A' {
		swap = 'B'
	}
	return cred[:len(cred)-1] + string(swap)
}

func splitList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

func randomSessionID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "turnprobe:", err)
	os.Exit(2)
}
