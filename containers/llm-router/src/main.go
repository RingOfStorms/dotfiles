// Command llm-router is the fleet's OpenAI-compatible LLM gateway: the static
// replacement for the LiteLLM proxy that used to serve :8094. It merges one
// model catalog over three upstreams (宙 Proxy "air", GitHub Copilot,
// OpenRouter) and bridges the two upstream dialects where a model only speaks
// one of them.
//
// Model ids keep the LiteLLM naming so existing clients (open-webui, omp,
// llm_chat) need no changes: air-<id>, copilot-<id>, openrouter/<slug>.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type config struct {
	listen         string
	airBase        string
	openrouterBase string
	copilotBase    string
	refresh        time.Duration
}

const (
	defaultAirBase        = "http://10.12.14.181:9010/air_prd"
	defaultOpenRouterBase = "https://openrouter.ai/api/v1"
	defaultCopilotBase    = "https://api.githubcopilot.com"
	// Inside the state dir (service.nix persist.data), so a device login
	// survives restarts and `cnt move`.
	defaultCopilotTokenFile = "/var/lib/llm-router/copilot-token"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	cfg := config{
		listen:         "0.0.0.0:8094",
		airBase:        defaultAirBase,
		openrouterBase: defaultOpenRouterBase,
		copilotBase:    defaultCopilotBase,
		refresh:        10 * time.Minute,
	}
	flag.StringVar(&cfg.listen, "listen", cfg.listen, "address to listen on")
	flag.StringVar(&cfg.airBase, "air-base", cfg.airBase, "宙 Proxy base URL")
	flag.StringVar(&cfg.openrouterBase, "openrouter-base", cfg.openrouterBase, "OpenRouter API base URL")
	flag.StringVar(&cfg.copilotBase, "copilot-base", cfg.copilotBase, "GitHub Copilot API base URL")
	flag.DurationVar(&cfg.refresh, "refresh", cfg.refresh, "catalog refresh interval")
	flag.Parse()

	cfg.airBase = strings.TrimRight(cfg.airBase, "/")
	cfg.openrouterBase = strings.TrimRight(cfg.openrouterBase, "/")
	cfg.copilotBase = strings.TrimRight(cfg.copilotBase, "/")

	s := newServer(cfg)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Load the catalog synchronously: a client connecting right after boot
	// must see a full model list. Upstream fetches run in parallel under one
	// deadline, so a dead upstream costs one timeout, not one per provider.
	s.refresh(ctx)
	go s.refreshLoop(ctx)
	go s.copilot.ensureToken(ctx)

	srv := &http.Server{
		Addr:              cfg.listen,
		Handler:           s.routes(),
		ReadHeaderTimeout: 30 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return ctx },
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()

	log.Printf("llm-router listening on %s", cfg.listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// refreshLoop re-reads every upstream catalog on an interval. While a provider
// has failed at least once, it retries on a short interval so a provider that
// was unreachable at boot appears within a minute instead of an hour.
func (s *server) refreshLoop(ctx context.Context) {
	for {
		delay := s.cfg.refresh
		if s.degraded() {
			delay = time.Minute
			if delay > s.cfg.refresh {
				delay = s.cfg.refresh
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
			s.refresh(ctx)
		}
	}
}
