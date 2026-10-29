// Command tmux-agents-mobile serves a phone-sized view of the agent panes on
// this machine's tmux server. It never attaches a client: it reads
// `capture-pane`, re-renders at phone width, and writes back with `send-keys`,
// so nothing it does can resize, zoom or select anything on a desktop.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/agents"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/auth"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/diff"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/dirs"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/watch"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/web"
)

type config struct {
	listen       string
	healthListen string
	tmuxBin      string
	tmuxSocket   string
	agentsBin    string
	gitBin       string
	roots        string
	devNoAuth    bool
	devTailnet   bool

	zitadelIssuer   string
	zitadelProject  string
	zitadelClaim    string
	zitadelClientID string
	zitadelRedirect string
	zitadelRole     string
	sessionKeyFile  string
	apiKeysFile     string
}

func main() {
	var cfg config
	flag.StringVar(&cfg.listen, "listen", envDefault("TAM_LISTEN", "127.0.0.1:8099"), "address for the UI (loopback when behind a proxy)")
	flag.StringVar(&cfg.healthListen, "health-listen", envDefault("TAM_HEALTH_LISTEN", "127.0.0.1:8098"), "loopback-only /healthz listener; empty disables it")
	flag.StringVar(&cfg.tmuxBin, "tmux", envDefault("TAM_TMUX", "tmux"), "tmux binary (must match the running server's version)")
	flag.StringVar(&cfg.tmuxSocket, "tmux-socket", envDefault("TAM_TMUX_SOCKET", ""), "tmux -L socket name; empty uses the default server")
	flag.StringVar(&cfg.agentsBin, "agents", envDefault("TAM_AGENTS", "tmux-agents"), "tmux-agents binary (rows --json); empty disables repo grouping")
	flag.StringVar(&cfg.gitBin, "git", envDefault("TAM_GIT", "git"), "git binary")
	flag.StringVar(&cfg.roots, "roots", envDefault("TAM_ROOTS", "~"),
		"colon-separated directories a new session may be created in (default: the home directory)")
	flag.BoolVar(&cfg.devNoAuth, "dev-no-auth", false, "disable authentication (loopback listen addresses only)")
	flag.BoolVar(&cfg.devTailnet, "dev-allow-tailnet", false, "allow --dev-no-auth on a non-loopback address (phone testing only)")

	flag.StringVar(&cfg.zitadelIssuer, "zitadel-issuer", envDefault("TAM_ZITADEL_ISSUER", ""), "Zitadel OIDC issuer")
	flag.StringVar(&cfg.zitadelProject, "zitadel-project-id", envDefault("TAM_ZITADEL_PROJECT_ID", ""), "Zitadel project ID")
	flag.StringVar(&cfg.zitadelClaim, "zitadel-claim", envDefault("TAM_ZITADEL_CLAIM", "flatRolesClaim"), "Zitadel claim holding flat role names")
	flag.StringVar(&cfg.zitadelClientID, "zitadel-client-id", envDefault("TAM_ZITADEL_CLIENT_ID", ""), "Zitadel PKCE client ID")
	flag.StringVar(&cfg.zitadelRedirect, "zitadel-redirect-uri", envDefault("TAM_ZITADEL_REDIRECT_URI", ""), "OIDC redirect URI; empty derives it from the request host")
	flag.StringVar(&cfg.zitadelRole, "zitadel-role", envDefault("TAM_ZITADEL_ROLE", ""), "required Zitadel role; empty allows any project member")
	flag.StringVar(&cfg.sessionKeyFile, "session-key-file", envDefault("TAM_SESSION_KEY_FILE", ""), "HMAC session key file; a random key is generated per boot when empty")
	flag.StringVar(&cfg.apiKeysFile, "api-keys-file", envDefault("TAM_API_KEYS_FILE", ""), "newline-delimited API keys (machines, tests)")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(context.Background(), cfg, log); err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config, log *slog.Logger) error {
	tmuxClient := tmux.New(cfg.tmuxBin, cfg.tmuxSocket)

	var sessionSecret []byte
	if cfg.sessionKeyFile != "" {
		b, err := os.ReadFile(cfg.sessionKeyFile)
		if err != nil {
			return fmt.Errorf("session key: %w", err)
		}
		sessionSecret = []byte(strings.TrimSpace(string(b)))
		if len(sessionSecret) < 16 {
			return errors.New("session key must be at least 16 bytes")
		}
	}

	authenticator, err := auth.New(auth.Config{
		Zitadel: auth.ZitadelConfig{
			Issuer:      cfg.zitadelIssuer,
			ProjectID:   cfg.zitadelProject,
			Claim:       cfg.zitadelClaim,
			ClientID:    cfg.zitadelClientID,
			RedirectURI: cfg.zitadelRedirect,
			AllowedRole: cfg.zitadelRole,
		},
		APIKeysFile:   cfg.apiKeysFile,
		SessionSecret: sessionSecret,
	})
	if err != nil {
		return fmt.Errorf("auth: %w", err)
	}

	if !authenticator.Enabled() {
		if !cfg.devNoAuth {
			return errors.New("no authentication configured: set TAM_ZITADEL_ISSUER and TAM_ZITADEL_CLIENT_ID, or pass --dev-no-auth")
		}
		if !isLoopback(cfg.listen) && !cfg.devTailnet {
			return fmt.Errorf("--dev-no-auth refuses to listen on %q; pass --dev-allow-tailnet to override", cfg.listen)
		}
		log.Warn("AUTHENTICATION DISABLED", "listen", cfg.listen, "reason", "--dev-no-auth")
	}

	hub := watch.New(tmuxClient, log)
	provider := agents.New(cfg.agentsBin, tmuxClient)
	provider.Log = log

	// One index of the home directory, shared by the new-session picker.
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("home directory: %w", err)
	}
	dirIndex := dirs.New(home)
	// Walk it now rather than on the first keystroke: the picker should open
	// with suggestions already there.
	go func() {
		if _, err := dirIndex.List(context.Background()); err != nil {
			log.Warn("directory index failed; the picker will fall back", "err", err)
		}
	}()
	webServer, err := web.New(tmuxClient, hub, provider, diff.New(cfg.gitBin), dirIndex, expandRoots(cfg.roots), cfg.devNoAuth, log)
	if err != nil {
		return err
	}

	ui := &http.Server{
		Addr:              cfg.listen,
		Handler:           authenticator.Wrap(webServer.Handler()),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	errs := make(chan error, 2)
	go func() {
		log.Info("listening",
			"addr", cfg.listen,
			"auth", authenticator.Enabled(),
			"tmux", cfg.tmuxBin,
			"socket", cfg.tmuxSocket,
			"agents", cfg.agentsBin,
			"roots", cfg.roots,
		)
		if err := ui.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}()

	var health *http.Server
	if cfg.healthListen != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("GET /healthz", webServer.Health)
		health = &http.Server{Addr: cfg.healthListen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
		go func() {
			if err := health.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errs <- err
			}
		}()
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errs:
		return err
	case sig := <-stop:
		log.Info("shutting down", "signal", sig.String())
	}

	shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_ = ui.Shutdown(shutdownCtx)
	if health != nil {
		_ = health.Shutdown(shutdownCtx)
	}
	return nil
}

func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "" {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func expandRoots(spec string) []string {
	home, _ := os.UserHomeDir()
	var roots []string
	for _, part := range strings.Split(spec, ":") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		switch {
		case part == "~":
			part = home
		case strings.HasPrefix(part, "~/"):
			part = filepath.Join(home, part[2:])
		}
		roots = append(roots, part)
	}
	return roots
}

func envDefault(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}
