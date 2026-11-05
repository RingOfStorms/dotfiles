// Command probe-server is the native end of the go-iroh browser probe.
//
// It binds a relay-only iroh endpoint on our own relay (no n0 relays, no DNS
// or pkarr discovery), echoes frames on proto.ALPN, and serves the wasm
// client page on a local HTTP address. Open the printed URL on the phone.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/tmc/go-iroh/iroh"
	"github.com/tmc/go-iroh/key"
	"github.com/tmc/go-iroh/netaddr"
	"github.com/tmc/go-iroh/relay"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/irohprobe/proto"
)

func main() {
	relayFlag := flag.String("relay", "https://relay.joshuabell.xyz/", "our iroh relay URL")
	keyFile := flag.String("key", filepath.Join(os.TempDir(), "irohprobe.key"), "endpoint secret key file (created if missing)")
	listen := flag.String("listen", "127.0.0.1:8097", "HTTP address serving the wasm page")
	webDir := flag.String("web", "", "directory with index.html, client.wasm, wasm_exec.js")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	if err := run(*relayFlag, *keyFile, *listen, *webDir, log); err != nil {
		log.Error("probe-server", "err", err)
		os.Exit(1)
	}
}

func loadKey(path string) (key.SecretKey, error) {
	if b, err := os.ReadFile(path); err == nil {
		return key.ParseSecretKey(strings.TrimSpace(string(b)))
	} else if !errors.Is(err, os.ErrNotExist) {
		return key.SecretKey{}, err
	}
	sk, err := key.GenerateSecretKey()
	if err != nil {
		return key.SecretKey{}, err
	}
	seed := sk.Bytes()
	return sk, os.WriteFile(path, []byte(hex.EncodeToString(seed[:])+"\n"), 0o600)
}

func run(relayStr, keyFile, listen, webDir string, log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	relayURL, err := netaddr.ParseRelayURL(relayStr)
	if err != nil {
		return fmt.Errorf("relay url: %w", err)
	}
	sk, err := loadKey(keyFile)
	if err != nil {
		return fmt.Errorf("key: %w", err)
	}
	// No WithAddressLookup / WithDNSResolver: nothing resolves through n0.
	ep, err := iroh.Bind(ctx,
		iroh.WithSecretKey(sk),
		iroh.WithALPNs(proto.ALPN),
		iroh.WithRelayMode(relay.ModeCustom(relay.MapFromURLs(relayURL))),
		iroh.WithTransportConfig(proto.Transport()),
	)
	if err != nil {
		return fmt.Errorf("bind: %w", err)
	}
	defer ep.Shutdown(context.Background())
	if err := ep.Online(ctx); err != nil {
		return fmt.Errorf("online via %s: %w", relayStr, err)
	}
	q := url.Values{"relay": {relayStr}, "peer": {ep.ID().String()}}
	log.Info("endpoint online", "id", ep.ID().String(), "relay", relayStr)
	fmt.Printf("\nopen on the phone:  <page origin>/?%s\n\n", q.Encode())

	if webDir != "" {
		go serveWeb(listen, webDir, q, log)
	}

	for {
		conn, err := ep.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		go func() {
			defer conn.CloseWithError(0, "")
			log.Info("connection", "remote", conn.RemoteID().String())
			for {
				s, err := conn.AcceptStream(ctx)
				if err != nil {
					return
				}
				go echo(s, log)
			}
		}()
	}
}

func echo(s io.ReadWriteCloser, log *slog.Logger) {
	defer s.Close()
	for {
		p, err := proto.ReadFrame(s)
		if err != nil {
			return
		}
		sum := sha256.Sum256(p)
		log.Info("frame", "bytes", len(p), "sha256", hex.EncodeToString(sum[:8]))
		if err := proto.WriteFrame(s, p); err != nil {
			return
		}
	}
}

func serveWeb(listen, dir string, q url.Values, log *slog.Logger) {
	mux := http.NewServeMux()
	fs := http.FileServer(http.Dir(dir))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" && r.URL.RawQuery == "" {
			http.Redirect(w, r, "/?"+q.Encode(), http.StatusFound)
			return
		}
		if strings.HasSuffix(r.URL.Path, ".wasm") {
			w.Header().Set("Content-Type", "application/wasm")
		}
		w.Header().Set("Cache-Control", "no-store")
		fs.ServeHTTP(w, r)
	})
	log.Info("serving probe page", "addr", listen)
	if err := http.ListenAndServe(listen, mux); err != nil {
		log.Error("web", "err", err)
	}
}
