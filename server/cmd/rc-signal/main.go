// Command rc-signal is the RemoteControl signaling server: device registry,
// access-code auth, presence, session management and SDP/ICE relay.
//
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
	"rc-signal/internal/hub"
	"rc-signal/internal/store"
	"rc-signal/internal/wsserver"
)

// env returns the environment override for a flag, if set.
func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func main() {
	var (
		addr       = flag.String("listen", env("RC_LISTEN", "0.0.0.0:8443"), "listen address (RC_LISTEN)")
		tlsCert    = flag.String("tls-cert", env("RC_TLS_CERT", ""), "TLS certificate path (RC_TLS_CERT)")
		tlsKey     = flag.String("tls-key", env("RC_TLS_KEY", ""), "TLS private key path (RC_TLS_KEY)")
		insecure   = flag.Bool("insecure-http", env("RC_INSECURE_HTTP", "") == "1", "serve plain HTTP — LOCAL TESTING ONLY (RC_INSECURE_HTTP=1)")
		dbPath     = flag.String("db", env("RC_DB", "rc-signal.db"), "SQLite path (RC_DB)")
		turnSecret = flag.String("turn-secret", env("RC_TURN_SECRET", ""), "coturn static-auth-secret (RC_TURN_SECRET)")
		turnURLs   = flag.String("turn-urls", env("RC_TURN_URLS", ""), "comma-separated TURN URLs (RC_TURN_URLS)")
		stunURLs   = flag.String("stun-urls", env("RC_STUN_URLS", "stun:stun.l.google.com:19302"), "comma-separated STUN URLs (RC_STUN_URLS)")
		tokenKey   = flag.String("token-secret", env("RC_TOKEN_SECRET", ""), "hex HMAC secret for session tokens; random if empty (RC_TOKEN_SECRET)")
		logLevel   = flag.String("log-level", env("RC_LOG_LEVEL", "info"), "debug|info|warn|error (RC_LOG_LEVEL)")
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

	st, err := store.Open(*dbPath)
	if err != nil {
		log.Error("could not open the device registry", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	signer, err := makeSigner(*tokenKey)
	if err != nil {
		log.Error("could not build the token signer", "err", err)
		os.Exit(1)
	}

	if *turnSecret == "" {
		log.Warn("no TURN secret configured; hello_ok will advertise STUN only")
	}

	h := hub.New(hub.Options{
		Store:      st,
		Clock:      clockx.Real{},
		Signer:     signer,
		Logger:     log,
		TurnSecret: *turnSecret,
		TurnURLs:   splitList(*turnURLs),
		StunURLs:   splitList(*stunURLs),
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
	log.Info("rc-signal started", "addr", *addr, "tls", !*insecure, "db", *dbPath)

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
