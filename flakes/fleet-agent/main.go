// Command fleet is the unified entrypoint for floating container orchestration
// (`fleet containers <cmd>`, aliased as `cnt`) and the per-host telemetry and
// status server (`fleet agent --listen ADDR`).
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"git.joshuabell.xyz/ringofstorms/fleet/internal/agent"
	"git.joshuabell.xyz/ringofstorms/fleet/internal/containers"
)

func usage() {
	fmt.Fprint(os.Stderr, `fleet - fleet container orchestration and host telemetry agent

usage:
  fleet containers [global flags] <command> [args...]   manage floating containers (alias: cnt)
  fleet agent --listen ADDR [--host NAME] [flags...]    run the per-host read-only status & metrics server
`)
}

func main() {
	base := filepath.Base(os.Args[0])
	args := os.Args[1:]

	// If invoked via `containers` or `cnt` symlink/alias directly, dispatch to containers.
	if base == "containers" || base == "cnt" {
		if len(args) > 0 && (args[0] == "agent" || args[0] == "status-server") {
			if err := agent.Run(args[1:]); err != nil {
				fmt.Fprintf(os.Stderr, "fleet agent: %v\n", err)
				os.Exit(1)
			}
			return
		}
		containers.Run(args)
		return
	}

	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	switch args[0] {
	case "containers", "cnt", "c":
		containers.Run(args[1:])
	case "agent", "status-server":
		if err := agent.Run(args[1:]); err != nil {
			fmt.Fprintf(os.Stderr, "fleet agent: %v\n", err)
			os.Exit(1)
		}
	case "help", "-h", "--help":
		usage()
	default:
		// Allow top-level container commands (`fleet ls`, `fleet deploy`, `fleet expose-expire`, etc.)
		// so existing scripts and systemd units work seamlessly with either `fleet containers <cmd>` or `fleet <cmd>`.
		containers.Run(args)
	}
}
