// Command rc-api is the SkipperDesk REST API of protocol/API.md: accounts,
// devices, entitlement, session accounting, credits, and the browser link page.
// It never stores a raw hardware id, a plaintext device token or link code, or session content.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"rc-signal/internal/apidb"
	"rc-signal/internal/apisrv"
	"rc-signal/internal/clientip"
	"rc-signal/internal/envx"
	"rc-signal/internal/idcert"
	"rc-signal/internal/idp"
	"rc-signal/internal/internalapi"
	"rc-signal/internal/sqlitex"
	protocol "rcprotocol"
)

const (
	idpDev         = "dev"
	idpCognito     = "cognito"
	purgeEvery     = 10 * time.Minute
	reconcileEvery = time.Minute
	readTimeouts   = 15 * time.Second
)

func main() {
	var (
		addr         = flag.String("listen", envx.Env("RC_API_LISTEN", "127.0.0.1:18080"), "public listen address (RC_API_LISTEN)")
		internalAddr = flag.String("internal-listen", envx.Env("RC_API_INTERNAL_LISTEN", "127.0.0.1:18081"), "internal listen address for rc-signal (RC_API_INTERNAL_LISTEN)")
		dbPath       = flag.String("db", envx.Env("RC_API_DB", "rc-api.db"), "SQLite path (RC_API_DB)")
		claimsPath   = flag.String("claims-db", envx.Env("RC_API_CLAIMS_DB", ""), "SQLite device-id claims path, backed up separately and never reset with -db; default <db>-claims (RC_API_CLAIMS_DB)")
		internal     = flag.String("internal-token", envx.Env("RC_API_INTERNAL_TOKEN", ""), "shared bearer secret for the internal surfaces (RC_API_INTERNAL_TOKEN)")
		idCertKey    = flag.String("id-cert-key-file", envx.Env("RC_API_ID_CERT_KEY_FILE", ""), "PEM PKCS#8 P-256 key that signs device-id certificates (RC_API_ID_CERT_KEY_FILE)")
		signalURL    = flag.String("signal-internal-url", envx.Env("RC_API_SIGNAL_INTERNAL_URL", ""), "rc-signal's internal base URL for the session reconciliation sweep (RC_API_SIGNAL_INTERNAL_URL)")
		trusted      = flag.String("trusted-proxies", envx.Env("RC_API_TRUSTED_PROXIES", ""), "comma-separated CIDRs whose X-Forwarded-For is honoured (RC_API_TRUSTED_PROXIES)")
		idpName      = flag.String("idp", envx.Env("RC_API_IDP", ""), "dev|cognito — how a user session is authenticated (RC_API_IDP)")
		issuer       = flag.String("cognito-issuer", envx.Env("RC_API_COGNITO_ISSUER", ""), "cognito issuer URL (RC_API_COGNITO_ISSUER)")
		audience     = flag.String("cognito-audience", envx.Env("RC_API_COGNITO_AUDIENCE", ""), "cognito app client id (RC_API_COGNITO_AUDIENCE)")
		salt         = flag.String("hardware-salt", envx.Env("RC_API_HARDWARE_SALT", ""), "server salt for the hardware hash (RC_API_HARDWARE_SALT)")
		webBase      = flag.String("web-base-url", envx.Env("RC_API_WEB_BASE_URL", ""), "the website this API belongs to (RC_API_WEB_BASE_URL)")
		upstream     = flag.String("signal-upstream", envx.Env("RC_API_SIGNAL_UPSTREAM", ""), "signaling server to pass /ws through to (RC_API_SIGNAL_UPSTREAM)")
		tlsCert      = flag.String("tls-cert", envx.Env("RC_API_TLS_CERT", ""), "TLS certificate path (RC_API_TLS_CERT)")
		tlsKey       = flag.String("tls-key", envx.Env("RC_API_TLS_KEY", ""), "TLS private key path (RC_API_TLS_KEY)")
		insecure     = flag.Bool("insecure-http", envx.Env("RC_API_INSECURE_HTTP", "") == "1", "serve plain HTTP — LOCAL TESTING ONLY (RC_API_INSECURE_HTTP=1)")
		logLevelIn   = flag.String("log-level", envx.Env("RC_API_LOG_LEVEL", "info"), "debug|info|warn|error (RC_API_LOG_LEVEL)")
	)
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: envx.LogLevel(*logLevelIn)}))
	slog.SetDefault(log)

	if !*insecure && (*tlsCert == "" || *tlsKey == "") {
		exit("-tls-cert and -tls-key are required unless -insecure-http is set")
	}
	if strings.TrimSpace(*internal) == "" {
		exit("-internal-token is required; it must match rc-signal's -internal-token")
	}
	if strings.TrimSpace(*salt) == "" {
		exit("-hardware-salt is required")
	}
	if err := internalapi.CheckSeparate(*addr, *internalAddr); err != nil {
		exit(err.Error())
	}
	resolver, err := clientip.Parse(*trusted)
	if err != nil {
		exit(err.Error())
	}
	authority, ephemeral, err := idcert.Open(*idCertKey, *insecure)
	if err != nil {
		exit(err.Error())
	}
	if ephemeral {
		log.Warn("no -id-cert-key-file: device-id certificates die with this process (local only)")
	}
	provider, err := makeIdP(*idpName, *insecure, *issuer, *audience)
	if err != nil {
		exit(err.Error())
	}
	var signaling *internalapi.Client
	if strings.TrimSpace(*signalURL) != "" {
		if signaling, err = internalapi.New(*signalURL, *internal); err != nil {
			exit(err.Error())
		}
	} else {
		log.Warn("no -signal-internal-url: open sessions are not reconciled against signaling")
	}

	if *claimsPath == "" {
		*claimsPath = sqlitex.SiblingPath(*dbPath, "-claims")
	}
	db, err := apidb.Open(*dbPath, *claimsPath)
	if err != nil {
		log.Error("could not open the API database", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	api, err := apisrv.New(apisrv.Options{
		DB: db, IdP: provider, IDCert: authority, InternalToken: *internal, HardwareSalt: []byte(*salt),
		WebBaseURL: *webBase, SignalUpstream: *upstream, ClientIP: resolver, Logger: log,
	})
	if err != nil {
		exit(err.Error())
	}

	srv := &http.Server{Addr: *addr, Handler: api, ReadHeaderTimeout: readTimeouts}
	// TODO: the internal listener becomes mTLS or VPC-only in Phase 5; today it is loopback plain HTTP with a bearer.
	internalSrv := &http.Server{Addr: *internalAddr, Handler: api.InternalHandler(), ReadHeaderTimeout: readTimeouts}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go purge(ctx, db, log)
	if signaling != nil {
		go reconcile(ctx, api, signaling, log)
	}

	errCh := make(chan error, 2)
	go func() {
		if *insecure {
			log.Warn("serving PLAINTEXT http — local testing only", "addr", *addr)
			errCh <- srv.ListenAndServe()
			return
		}
		errCh <- srv.ListenAndServeTLS(*tlsCert, *tlsKey)
	}()
	go func() { errCh <- internalSrv.ListenAndServe() }()
	log.Info("rc-api started", "addr", *addr, "internalAddr", *internalAddr, "tls", !*insecure, "db", *dbPath,
		"claimsDb", *claimsPath,
		"idp", provider.Name(), "signalUpstream", *upstream, "reconcile", signaling != nil)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
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
		_ = internalSrv.Shutdown(shutCtx)
		cancel()
		log.Info("stopped")
	}
}

func makeIdP(name string, insecure bool, issuer, audience string) (idp.Provider, error) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case idpDev:
		if !insecure {
			return nil, errors.New("the dev identity provider is local only: pass -insecure-http or use -idp cognito")
		}
		return idp.Dev{}, nil
	case idpCognito:
		return idp.NewCognito(issuer, audience)
	case "":
		return nil, errors.New("-idp is required (dev|cognito)")
	default:
		return nil, fmt.Errorf("unknown -idp %q: want dev or cognito", name)
	}
}

func purge(ctx context.Context, db *apidb.DB, log *slog.Logger) {
	t := time.NewTicker(purgeEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if err := db.PurgeExpired(now.UnixMilli()); err != nil {
				log.Warn("purge failed", "err", err)
			}
			if err := db.ExpirePendingGifts(now.UnixMilli()); err != nil {
				log.Warn("gift expiry failed", "err", err)
			}
		}
	}
}

func reconcile(ctx context.Context, api *apisrv.Server, signaling *internalapi.Client, log *slog.Logger) {
	live := func(ctx context.Context) (protocol.InternalLiveSessions, error) {
		var out protocol.InternalLiveSessions
		resp, err := signaling.Do(ctx, http.MethodGet, protocol.PathInternalLiveSessions, nil)
		if err != nil {
			return out, err
		}
		if !resp.OK() {
			return out, fmt.Errorf("signaling live sessions: status %d", resp.Status)
		}
		return out, resp.Decode(&out)
	}
	t := time.NewTicker(reconcileEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			closed, err := api.Reconcile(ctx, live)
			if err != nil {
				log.Warn("session reconciliation skipped", "err", err)
				continue
			}
			if closed > 0 {
				log.Info("session reconciliation closed rows", "closed", closed)
			}
		}
	}
}

func exit(message string) {
	fmt.Fprintln(os.Stderr, "rc-api: "+message)
	os.Exit(2)
}
