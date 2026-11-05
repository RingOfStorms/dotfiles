//go:build js

// Command probe-client is the browser end: relay-only iroh over WebSocket.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"net/url"
	"syscall/js"
	"time"

	"github.com/tmc/go-iroh/iroh"
	"github.com/tmc/go-iroh/key"
	"github.com/tmc/go-iroh/netaddr"
	"github.com/tmc/go-iroh/relay"

	"git.joshuabell.xyz/ringofstorms/tmux-agents-mobile/irohprobe/proto"
)

func main() {
	go func() {
		if err := run(); err != nil {
			logLine("FAIL: " + err.Error())
			status("fail")
			return
		}
		status("pass")
	}()
	select {}
}

func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	u, _ := url.Parse(js.Global().Get("location").Get("href").String())
	q := u.Query()
	relayURL, err := netaddr.ParseRelayURL(q.Get("relay"))
	if err != nil {
		return fmt.Errorf("relay: %w", err)
	}
	peer, err := key.ParseEndpointID(q.Get("peer"))
	if err != nil {
		return fmt.Errorf("peer: %w", err)
	}
	t0 := time.Now()
	ep, err := iroh.Bind(ctx,
		iroh.WithRelayMode(relay.ModeCustom(relay.MapFromURLs(relayURL))),
		iroh.WithoutIPTransports(),
		iroh.WithTransportConfig(proto.Transport()),
	)
	if err != nil {
		return fmt.Errorf("bind: %w", err)
	}
	defer ep.Shutdown(context.Background())
	if err := ep.Online(ctx); err != nil {
		return fmt.Errorf("online: %w", err)
	}
	logLine(fmt.Sprintf("online via %s in %v (me %s)", relayURL, time.Since(t0).Round(time.Millisecond), ep.ID().String()[:10]))

	t1 := time.Now()
	conn, err := ep.Connect(ctx, netaddr.NewEndpointAddr(peer).WithRelayURL(relayURL), proto.ALPN)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.CloseWithError(0, "")
	logLine(fmt.Sprintf("connected to %s in %v", peer.String()[:10], time.Since(t1).Round(time.Millisecond)))

	s, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return fmt.Errorf("stream: %w", err)
	}
	defer s.Close()
	for _, n := range []int{16, 1024, 64 * 1024, 256 * 1024} {
		p := make([]byte, n)
		_, _ = rand.Read(p)
		t := time.Now()
		if err := proto.WriteFrame(s, p); err != nil {
			return fmt.Errorf("write %d: %w", n, err)
		}
		got, err := proto.ReadFrame(s)
		if err != nil {
			return fmt.Errorf("read %d: %w", n, err)
		}
		if !bytes.Equal(got, p) {
			return fmt.Errorf("echo mismatch at %d bytes", n)
		}
		logLine(fmt.Sprintf("echo %7d B  rtt %v", n, time.Since(t).Round(time.Millisecond)))
	}
	return nil
}

func logLine(s string) {
	doc := js.Global().Get("document")
	el := doc.Call("createElement", "div")
	el.Set("textContent", s)
	doc.Call("getElementById", "log").Call("appendChild", el)
}

func status(s string) {
	js.Global().Get("document").Get("body").Call("setAttribute", "data-status", s)
	logLine("status: " + s)
}
