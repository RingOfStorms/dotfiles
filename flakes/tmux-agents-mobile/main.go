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
	"strconv"
	"strings"
	"syscall"
	"time"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/agents"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/auth"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/diff"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/dirs"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tailnet"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/term"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/tmux"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/transcript"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/watch"
	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/internal/web"
)

type config struct {
	listen           string
	healthListen     string
	tmuxBin          string
	tmuxSocket       string
	agentsBin        string
	gitBin           string
	roots            string
	noAuth           bool
	allowNonLoopback bool
	shell            string
	termDetach       time.Duration

	zitadelIssuer   string
	zitadelProject  string
	zitadelClaim    string
	zitadelClientID string
	zitadelRedirect string
	zitadelRole     string
	sessionKeyFile  string
	apiKeysFile     string

	// tsnet: the UI on its own tailnet node. Off while tsnetHostname is empty.
	tsnetHostname    string
	tsnetDir         string
	tsnetControlURL  string
	tsnetAuthKeyFile string
	tsnetListen      string
}

func main() {
	var cfg config
	flag.StringVar(&cfg.listen, "listen", envDefault("TAM_LISTEN", "127.0.0.1:8099"), "address for the UI (loopback when behind a proxy); empty disables it")
	flag.StringVar(&cfg.healthListen, "health-listen", envDefault("TAM_HEALTH_LISTEN", "127.0.0.1:8098"), "loopback-only /healthz listener; empty disables it")
	flag.StringVar(&cfg.tmuxBin, "tmux", envDefault("TAM_TMUX", "tmux"), "tmux binary (must match the running server's version)")
	flag.StringVar(&cfg.tmuxSocket, "tmux-socket", envDefault("TAM_TMUX_SOCKET", ""), "tmux -L socket name; empty uses the default server")
	flag.StringVar(&cfg.agentsBin, "agents", envDefault("TAM_AGENTS", "tmux-agents"), "tmux-agents binary (rows --json); empty disables repo grouping")
	flag.StringVar(&cfg.gitBin, "git", envDefault("TAM_GIT", "git"), "git binary")
	flag.StringVar(&cfg.roots, "roots", envDefault("TAM_ROOTS", "~"),
		"colon-separated directories a new session may be created in (default: the home directory)")
	flag.BoolVar(&cfg.noAuth, "no-auth", envBool("TAM_NO_AUTH"), "serve without authentication; the listener must be loopback unless --allow-nonloopback (env TAM_NO_AUTH)")
	flag.BoolVar(&cfg.allowNonLoopback, "allow-nonloopback", false, "permit --no-auth on a non-loopback address (unsafe: anyone who can reach it gets a shell)")
	// Old names, kept so existing scripts and muscle memory keep working.
	legacyNoAuth := flag.Bool("dev-no-auth", false, "alias for --no-auth")
	legacyTailnet := flag.Bool("dev-allow-tailnet", false, "alias for --allow-nonloopback")
	flag.StringVar(&cfg.shell, "shell", envDefault("TAM_SHELL", ""), "login shell for the terminal tab; empty uses $SHELL, then the passwd entry")
	flag.DurationVar(&cfg.termDetach, "term-detach", envDuration("TAM_TERM_DETACH", time.Hour), "how long a terminal shell with no browser attached is kept")

	flag.StringVar(&cfg.zitadelIssuer, "zitadel-issuer", envDefault("TAM_ZITADEL_ISSUER", ""), "Zitadel OIDC issuer")
	flag.StringVar(&cfg.zitadelProject, "zitadel-project-id", envDefault("TAM_ZITADEL_PROJECT_ID", ""), "Zitadel project ID")
	flag.StringVar(&cfg.zitadelClaim, "zitadel-claim", envDefault("TAM_ZITADEL_CLAIM", "flatRolesClaim"), "Zitadel claim holding flat role names")
	flag.StringVar(&cfg.zitadelClientID, "zitadel-client-id", envDefault("TAM_ZITADEL_CLIENT_ID", ""), "Zitadel PKCE client ID")
	flag.StringVar(&cfg.zitadelRedirect, "zitadel-redirect-uri", envDefault("TAM_ZITADEL_REDIRECT_URI", ""), "OIDC redirect URI; empty derives it from the request host")
	flag.StringVar(&cfg.zitadelRole, "zitadel-role", envDefault("TAM_ZITADEL_ROLE", ""), "required Zitadel role; empty allows any project member")
	flag.StringVar(&cfg.sessionKeyFile, "session-key-file", envDefault("TAM_SESSION_KEY_FILE", ""), "HMAC session key file; a random key is generated per boot when empty")
	flag.StringVar(&cfg.apiKeysFile, "api-keys-file", envDefault("TAM_API_KEYS_FILE", ""), "newline-delimited API keys (machines, tests)")

	flag.StringVar(&cfg.tsnetHostname, "tsnet-hostname", envDefault("TAM_TSNET_HOSTNAME", ""),
		"also serve the UI from its own tailnet node with this name; reaching it is the authentication (tailnet ACLs decide who can). Empty disables it")
	flag.StringVar(&cfg.tsnetControlURL, "tsnet-control-url", envDefault("TAM_TSNET_CONTROL_URL", ""), "tailnet coordination server (Headscale URL); empty uses Tailscale's")
	flag.StringVar(&cfg.tsnetAuthKeyFile, "tsnet-authkey-file", envDefault("TAM_TSNET_AUTHKEY_FILE", ""),
		"pre-auth key for the node's first login; empty falls back to $TS_AUTHKEY, then a login URL in the log")
	flag.StringVar(&cfg.tsnetDir, "tsnet-dir", envDefault("TAM_TSNET_DIR", ""), "tailnet node state (keys); empty uses <user config dir>/tmux-agents-mobile/tsnet")
	flag.StringVar(&cfg.tsnetListen, "tsnet-listen", envDefault("TAM_TSNET_LISTEN", ":80"), "listen address on the tailnet node")
	flag.Parse()
	cfg.noAuth = cfg.noAuth || *legacyNoAuth
	cfg.allowNonLoopback = cfg.allowNonLoopback || *legacyTailnet

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

	tailnetOn := cfg.tsnetHostname != ""
	if cfg.listen == "" && !tailnetOn {
		return errors.New("nothing to serve: --listen is empty and --tsnet-hostname is not set")
	}
	if cfg.listen != "" && !authenticator.Enabled() {
		if !cfg.noAuth {
			return errors.New("no authentication configured: set TAM_ZITADEL_ISSUER and TAM_ZITADEL_CLIENT_ID, or pass --no-auth for a local-only server (with --tsnet-hostname, --listen '' serves only the tailnet node)")
		}
		if !isLoopback(cfg.listen) && !cfg.allowNonLoopback {
			return fmt.Errorf("--no-auth refuses to listen on %q (it would be wide open); pass --allow-nonloopback to override", cfg.listen)
		}
		log.Warn("AUTHENTICATION DISABLED: every route is open to whoever can reach the listener", "listen", cfg.listen)
	}

	hub := watch.New(tmuxClient, log)
	locator := transcript.NewLocator()
	history := transcript.NewHistory(locator.OmpDir)
	defer history.Close()
	defer locator.OpenCode.Close()
	chatHub := watch.NewChatHub(tmuxClient, locator, history, web.ChatRenderer, log)
	git := diff.New(cfg.gitBin)

	provider := agents.New(cfg.agentsBin, tmuxClient)
	provider.Log = log
	provider.Git = git

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
	shell := cfg.shell
	if shell == "" {
		shell = term.LoginShell()
	}
	terms := term.NewManager(term.Config{
		Shell:  shell,
		Dir:    home,
		Env:    term.ShellEnv(os.Environ()),
		Detach: cfg.termDetach,
		Log:    log,
	})
	defer terms.Close()
	roots := expandRoots(cfg.roots)
	webServer, err := web.New(tmuxClient, hub, chatHub, provider, git, dirIndex, roots, terms, !authenticator.Enabled(), log)
	if err != nil {
		return err
	}
	newUI := func(h http.Handler) *http.Server {
		return &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
	}
	errs := make(chan error, 3)
	serve := func(srv *http.Server, ln net.Listener) {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}
	var servers []*http.Server

	if cfg.listen != "" {
		ln, err := net.Listen("tcp", cfg.listen)
		if err != nil {
			return err
		}
		ui := newUI(authenticator.Wrap(webServer.Handler()))
		servers = append(servers, ui)
		log.Info("listening",
			"addr", cfg.listen,
			"auth", authenticator.Enabled(),
			"tmux", cfg.tmuxBin,
			"socket", cfg.tmuxSocket,
			"agents", cfg.agentsBin,
			"roots", cfg.roots,
		)
		go serve(ui, ln)
	}

	if tailnetOn {
		dir := cfg.tsnetDir
		if dir == "" {
			base, err := os.UserConfigDir()
			if err != nil {
				return fmt.Errorf("tsnet state directory: %w", err)
			}
			dir = filepath.Join(base, "tmux-agents-mobile", "tsnet")
		}
		// Reaching the node is the authentication, so its pages carry no login
		// and no sign-out.
		tailnetWeb, err := web.New(tmuxClient, hub, chatHub, provider, git, dirIndex, roots, terms, true, log)
		if err != nil {
			return err
		}
		node, ln, err := tailnet.Listen(tailnet.Config{
			Hostname:    cfg.tsnetHostname,
			Dir:         dir,
			ControlURL:  cfg.tsnetControlURL,
			AuthKeyFile: cfg.tsnetAuthKeyFile,
			Addr:        cfg.tsnetListen,
			Log:         log,
		})
		if err != nil {
			return err
		}
		defer node.Close()
		ts := newUI(node.Guard(tailnetWeb.Handler()))
		servers = append(servers, ts)
		go serve(ts, ln)

		upCtx, cancelUp := context.WithCancel(ctx)
		defer cancelUp()
		go func() {
			name, ips, err := node.Up(upCtx)
			if err != nil {
				if upCtx.Err() == nil {
					log.Error("tailnet node did not come up", "err", err)
				}
				return
			}
			log.Info("listening on the tailnet", "name", name, "ips", ips, "addr", cfg.tsnetListen, "dir", dir)
		}()
	}

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
	for _, srv := range servers {
		_ = srv.Shutdown(shutdownCtx)
	}
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

// envBool reads a boolean ("1", "true") from the environment; unset or
// unparsable is false.
func envBool(key string) bool {
	v, _ := strconv.ParseBool(os.Getenv(key))
	return v
}

// envDuration parses a Go duration ("45m", "2h") from the environment; an
// unset or unparsable value keeps the default.
func envDuration(key string, def time.Duration) time.Duration {
	if d, err := time.ParseDuration(os.Getenv(key)); err == nil && d > 0 {
		return d
	}
	return def
}
