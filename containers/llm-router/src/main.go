// Command llm-router is a generic OpenAI-compatible gateway. It merges model
// catalogs from configured upstreams and bridges model API dialects where
// needed.

// Public model IDs are namespaced by upstream identity: <name>-<id> for
// LiteLLM and Copilot upstreams, and <name>/<id> for OpenRouter.
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
	"syscall"
	"time"
)

type config struct {
	listen    string
	upstreams []upstreamConfig
	refresh   time.Duration
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	cfg := config{
		listen:  "0.0.0.0:8094",
		refresh: 10 * time.Minute,
	}
	var upstreamsPath string
	flag.StringVar(&cfg.listen, "listen", cfg.listen, "address to listen on")
	flag.StringVar(&upstreamsPath, "upstreams", "", "JSON upstream configuration file")
	flag.DurationVar(&cfg.refresh, "refresh", cfg.refresh, "catalog refresh interval")
	flag.Parse()
	if upstreamsPath == "" {
		log.Fatal("--upstreams is required")
	}
	var err error
	cfg.upstreams, err = loadUpstreams(upstreamsPath)
	if err != nil {
		log.Fatalf("invalid --upstreams configuration: %v", err)
	}

	s := newServer(cfg)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Load the catalog synchronously: a client connecting right after boot
	// must see a full model list. Upstream fetches run in parallel under one
	// deadline, so a dead upstream costs one timeout, not one per upstream.
	s.refresh(ctx)
	go s.refreshLoop(ctx)
	if s.hasCopilot() {
		go s.copilot.ensureToken(ctx)
	}

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

// refreshLoop re-reads every configured upstream catalog on an interval. While
// an upstream has failed, it retries on a short interval so it can recover
// quickly.
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
