// Command rc-signal is the SkipperDesk signaling server.
// It never sees media, input or clipboard content, and never logs secrets.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"rc-signal/internal/auth"
	"rc-signal/internal/clockx"
	"rc-signal/internal/entitlement"
	"rc-signal/internal/envx"
	"rc-signal/internal/hub"
	"rc-signal/internal/internalapi"
	"rc-signal/internal/registry"
	"rc-signal/internal/store"
	"rc-signal/internal/wsserver"
)

func main() {
	var (
		addr       = flag.String("listen", envx.Env("RC_LISTEN", "0.0.0.0:8443"), "listen address (RC_LISTEN)")
		tlsCert    = flag.String("tls-cert", envx.Env("RC_TLS_CERT", ""), "TLS certificate path (RC_TLS_CERT)")
		tlsKey     = flag.String("tls-key", envx.Env("RC_TLS_KEY", ""), "TLS private key path (RC_TLS_KEY)")
		insecure   = flag.Bool("insecure-http", envx.Env("RC_INSECURE_HTTP", "") == "1", "serve plain HTTP — LOCAL TESTING ONLY (RC_INSECURE_HTTP=1)")
		dbPath     = flag.String("db", envx.Env("RC_DB", "rc-signal.db"), "static mode only: SQLite device registry path (RC_DB)")
		turnSecret = flag.String("turn-secret", envx.Env("RC_TURN_SECRET", ""), "coturn static-auth-secret (RC_TURN_SECRET)")
		turnURLs   = flag.String("turn-urls", envx.Env("RC_TURN_URLS", ""), "comma-separated TURN URLs (RC_TURN_URLS)")
		stunURLs   = flag.String("stun-urls", envx.Env("RC_STUN_URLS", "stun:stun.l.google.com:19302"), "comma-separated STUN URLs (RC_STUN_URLS)")
		tokenKey   = flag.String("token-secret", envx.Env("RC_TOKEN_SECRET", ""), "hex HMAC secret for session tokens; random if empty (RC_TOKEN_SECRET)")
		logLevel   = flag.String("log-level", envx.Env("RC_LOG_LEVEL", "info"), "debug|info|warn|error (RC_LOG_LEVEL)")
		entMode    = flag.String("entitlement", envx.Env("RC_ENTITLEMENT", ""), "static|http — how connect_req is authorised (RC_ENTITLEMENT)")
		entDeny    = flag.String("entitlement-deny", envx.Env("RC_ENTITLEMENT_DENY", ""), "static mode only: comma-separated <deviceId>|label:<label>[=<reason>] deny list (RC_ENTITLEMENT_DENY)")
		apiURL     = flag.String("api-internal-url", envx.Env("RC_API_INTERNAL_URL", ""), "http mode only: rc-api internal base URL; it owns the device registry and entitlement (RC_API_INTERNAL_URL)")
		apiToken   = flag.String("internal-token", envx.Env("RC_INTERNAL_TOKEN", ""), "http mode only: shared bearer secret for the internal API (RC_INTERNAL_TOKEN)")
	)
	flag.Parse()

	lvl := slog.LevelInfo
	switch strings.ToLower(*logLevel) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
	slog.SetDefault(log)

	if !*insecure && (*tlsCert == "" || *tlsKey == "") {
		fmt.Fprintln(os.Stderr, "rc-signal: -tls-cert and -tls-key are required unless -insecure-http is set")
		os.Exit(2)
	}

	signer, err := makeSigner(*tokenKey)
	if err != nil {
		log.Error("could not build the token signer", "err", err)
		os.Exit(1)
	}

	backend, err := makeBackend(*entMode, *insecure, *entDeny, *apiURL, *apiToken, *dbPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "rc-signal: "+err.Error())
		os.Exit(2)
	}
	defer backend.close()

	if *turnSecret == "" {
		log.Warn("no TURN secret configured; hello_ok will advertise STUN only")
	}

	h := hub.New(hub.Options{
		Registry:    backend.registry,
		Entitlement: backend.entitlement,
		Clock:       clockx.Real{},
		Signer:      signer,
		Logger:      log,
		TurnSecret:  *turnSecret,
		TurnURLs:    splitList(*turnURLs),
		StunURLs:    splitList(*stunURLs),
	})

	srv := wsserver.New(wsserver.Config{
		Addr: *addr, TLSCert: *tlsCert, TLSKey: *tlsKey,
		InsecureHTTP: *insecure, Logger: log,
	}, h)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go wsserver.RunSweeper(ctx, h)

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	log.Info("rc-signal started", "addr", *addr, "tls", !*insecure,
		"entitlement", entitlementMode(*entMode, *insecure), "registry", backend.describe)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, context.Canceled) {
			log.Error("server stopped", "err", err)
			os.Exit(1)
		}
	case s := <-sigCh:
		log.Info("shutting down", "signal", s.String())
		shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutCancel()
		if err := srv.Shutdown(shutCtx); err != nil {
			log.Error("graceful shutdown failed", "err", err)
		}
		cancel()
		log.Info("stopped")
	}
}

func entitlementMode(mode string, insecure bool) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" && insecure {
		return modeStatic
	}
	return mode
}

const (
	modeStatic = "static"
	modeHTTP   = "http"
)

type backend struct {
	registry    registry.Registry
	entitlement entitlement.Entitlement
	describe    string
	close       func()
}

// makeBackend pairs the registry with the entitlement source: http mode means rc-api owns both.
func makeBackend(mode string, insecure bool, deny, apiURL, apiToken, dbPath string) (*backend, error) {
	switch entitlementMode(mode, insecure) {
	case modeStatic:
		st, err := store.Open(dbPath)
		if err != nil {
			return nil, fmt.Errorf("could not open the device registry: %w", err)
		}
		ent, err := entitlement.NewStatic(deny, func(deviceID string) string {
			d, err := st.GetDevice(deviceID)
			if err != nil {
				return ""
			}
			return d.Label
		})
		if err != nil {
			st.Close()
			return nil, err
		}
		return &backend{
			registry: registry.NewLocal(st, clockx.Real{}), entitlement: ent,
			describe: "local:" + dbPath, close: func() { st.Close() },
		}, nil
	case modeHTTP:
		api, err := internalapi.New(apiURL, apiToken)
		if err != nil {
			return nil, err
		}
		return &backend{
			registry: registry.NewHTTP(api, clockx.Real{}), entitlement: entitlement.NewHTTP(api),
			describe: "http", close: func() {},
		}, nil
	case "":
		return nil, errors.New("-entitlement is required (static|http) unless -insecure-http is set")
	default:
		return nil, fmt.Errorf("unknown -entitlement %q: want static or http", mode)
	}
}

func makeSigner(hexKey string) (*auth.Signer, error) {
	if hexKey == "" {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		return auth.NewSigner(b), nil
	}
	b, err := hex.DecodeString(hexKey)
	if err != nil {
		return nil, fmt.Errorf("token secret must be hex: %w", err)
	}
	if len(b) < 16 {
		return nil, errors.New("token secret must be at least 16 bytes (32 hex chars)")
	}
	return auth.NewSigner(b), nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
