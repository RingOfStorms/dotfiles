// Command fleet-edge serves the read-only fleet dashboard described in
// containers/ROUTING-PLAN.md §5.2 and §5.4: a table of every service
// (declared vs. polled state, routes, description) and a per-host poll
// status page, backed by the static inventory plus each host's status
// endpoint (contract documented in internal/state).
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/server"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8099", "address to bind the HTTP server to")
	inventoryFile := flag.String("inventory", "", "path to inventory JSON (nix eval --json <containers-flake>#inventory)")
	statusURLTemplate := flag.String("status-url-template", "http://{overlayIp}:9101/status.json",
		"per-host status endpoint URL template; {overlayIp}, {lanIp} and {host} are substituted")
	pollInterval := flag.Duration("poll-interval", 30*time.Second, "how often to poll each host's status endpoint")
	pollTimeout := flag.Duration("poll-timeout", 3*time.Second, "per-host poll timeout")
	flag.Parse()

	if *inventoryFile == "" {
		log.Fatal("--inventory is required")
	}

	inv, err := inventory.Load(*inventoryFile)
	if err != nil {
		log.Fatalf("loading inventory: %v", err)
	}

	poller := state.NewPoller(inv, *statusURLTemplate, *pollTimeout)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	go poller.Run(ctx, *pollInterval)

	srv := server.New(poller)
	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           srv,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("fleet-edge listening on %s (inventory=%s)", *listen, *inventoryFile)
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}
