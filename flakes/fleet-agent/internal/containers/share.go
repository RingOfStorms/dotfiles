package containers

// `fleet share` (containers/FLOWS-AUDIT.md §(c) "Local temporary sharing via
// *.share.joshuabell.xyz"): share a local port under a temporary subdomain
// via a restricted ssh reverse tunnel to o002's `share` user, whose forced
// command (`fleet-share-serve`, o002-side, fleet-edge `internal/shareserve`)
// renders and tears down the nginx vhost itself. There is no host-side
// state at all: the whole feature lives in one ssh connection.
//
// Usage: fleet share <port> [--name N] [--for DUR]
//
// Two ssh phases over one multiplexed connection (control socket), because
// the forced command needs to know which port sshd ends up binding for
// `-R 127.0.0.1:0:...` (port 0: let the server pick), and the only way to
// learn that before the forced command runs is to ask the connection
// itself once it exists:
//
//  1. A background ControlMaster with `-N` (no session/command requested
//     at all, so `share`'s ForceCommand never fires) opens the connection
//     and requests the `-R 127.0.0.1:0:localhost:<port>` forward.
//  2. `ssh -S <ctrl> -O forward` on the same control path asks the running
//     master to (re-)establish configured forwards and prints the
//     allocated port to stdout (documented OpenSSH pattern, see
//     PROTOCOL.mux: `LPORT=$(ssh -S muxsocket -R0:localhost:25 -O forward
//     somehost)`).
//  3. A second, foreground `ssh -S <ctrl>` session with an explicit remote
//     command (`<name> <boundport> <forSeconds>`) reuses the same
//     connection and *does* request a session, so this is the one that
//     triggers the forced command: it receives the command in
//     $SSH_ORIGINAL_COMMAND, independently verifies the port belongs to
//     this very connection's sshd (via `ss`+parent pid, not trusted from
//     the client), writes and reloads the vhost, and blocks until this
//     session ends.
//  4. When that foreground session exits (Ctrl-C, network loss, or the
//     server's own --for cap), the control master is torn down
//     (`-O exit`), closing the `-R` forward too.
import (
	"bytes"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"time"
)

const shareNameLowerBase32 = "abcdefghijklmnopqrstuvwxyz234567"

// genShareName returns 6 random lowercase base32 characters.
func genShareName() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, 6)
	for i, c := range b {
		out[i] = shareNameLowerBase32[int(c)%len(shareNameLowerBase32)]
	}
	return string(out), nil
}

var shareNameRe = regexp.MustCompile(`^[a-z0-9-]{1,63}$`)

// allocatedPortRe matches OpenSSH's "Allocated port N for remote forward
// to ..." message, printed to the client's stderr when a `-R ...:0:...`
// (port 0) forward is set up.
var allocatedPortRe = regexp.MustCompile(`Allocated port (\d+) for remote forward`)

// shareFor parses --for: default 8h, max 24h (fleet-share-serve enforces
// the same cap independently; this is just an early, friendly refusal).
func shareFor(v string) (time.Duration, error) {
	if v == "" {
		return 8 * time.Hour, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("--for %q: %v", v, err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("--for %q must be positive", v)
	}
	if d > 24*time.Hour {
		return 0, fmt.Errorf("--for %q exceeds the 24h max", v)
	}
	return d, nil
}

type shareArgs struct {
	Port int
	Name string
	For  time.Duration
}

func parseShareArgs(args []string) (shareArgs, error) {
	var a shareArgs
	forStr := ""
	var rest []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--name":
			i++
			if i >= len(args) {
				return a, fmt.Errorf("--name needs a value")
			}
			a.Name = args[i]
		case "--for":
			i++
			if i >= len(args) {
				return a, fmt.Errorf("--for needs a value")
			}
			forStr = args[i]
		default:
			rest = append(rest, args[i])
		}
	}
	if len(rest) != 1 {
		return a, fmt.Errorf("usage: fleet share <port> [--name N] [--for DUR]")
	}
	port, err := strconv.Atoi(rest[0])
	if err != nil || port < 1 || port > 65535 {
		return a, fmt.Errorf("port %q out of range", rest[0])
	}
	a.Port = port
	if a.Name == "" {
		name, err := genShareName()
		if err != nil {
			return a, err
		}
		a.Name = name
	}
	if !shareNameRe.MatchString(a.Name) {
		return a, fmt.Errorf("--name %q: want [a-z0-9-]{1,63}", a.Name)
	}
	d, err := shareFor(forStr)
	if err != nil {
		return a, err
	}
	a.For = d
	return a, nil
}

// shareDomain is the public domain `fleet share` tunnels vhosts under.
func shareDomain() string {
	if d := os.Getenv("FLEET_SHARE_DOMAIN"); d != "" {
		return d
	}
	return "share." + rootDomain()
}

// rootDomain returns the home domain ("joshuabell.xyz"), overridable for
// tests/non-default setups.
func rootDomain() string {
	if d := os.Getenv("FLEET_DOMAIN"); d != "" {
		return d
	}
	return "joshuabell.xyz"
}

func shareTarget() string {
	if t := os.Getenv("FLEET_SHARE_TARGET"); t != "" {
		return t
	}
	return "share@o002." + rootDomain()
}

// runSSH runs the args with the given stdio, var for tests.
var runSSH = func(args []string, stdout, stderr *os.File) error {
	cmd := exec.Command("ssh", args...)
	cmd.Stdout, cmd.Stderr, cmd.Stdin = stdout, stderr, os.Stdin
	return cmd.Run()
}

// Share runs `fleet share` (top-level entry point from main.go).
func Share(args []string) error {
	a, err := parseShareArgs(args)
	if err != nil {
		return err
	}
	target := shareTarget()

	ctrlDir, err := os.MkdirTemp("", "fleet-share-ctrl-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(ctrlDir)
	ctrl := filepath.Join(ctrlDir, "sock")

	// Phase 1: background master, no session at all (so share's
	// ForceCommand never runs), just the reverse forward. OpenSSH prints
	// "Allocated port N for remote forward to ..." for a `-R ...:0:...`
	// (port 0) request to its OWN stderr at setup time (ssh.c
	// channel_request_remote_forwarding); capture that instead of `-O
	// forward`, whose stdout-prints-the-port behavior (PROTOCOL.mux) isn't
	// observed on OpenSSH 10.5 (empty stdout).
	var masterErr bytes.Buffer
	master := exec.Command("ssh",
		"-M", "-S", ctrl, "-f", "-N",
		"-o", "ExitOnForwardFailure=yes",
		"-o", "ControlPersist=yes",
		"-R", fmt.Sprintf("127.0.0.1:0:localhost:%d", a.Port),
		target,
	)
	master.Stdout, master.Stdin = nil, nil
	master.Stderr = io.MultiWriter(os.Stderr, &masterErr)
	if err := master.Run(); err != nil {
		return fmt.Errorf("ssh master: %w", err)
	}
	defer exec.Command("ssh", "-S", ctrl, "-O", "exit", target).Run() //nolint:errcheck

	// Phase 2: pull the bound port out of the master's own setup message.
	m := allocatedPortRe.FindSubmatch(masterErr.Bytes())
	if m == nil {
		return fmt.Errorf("could not find the allocated port in ssh output (%q)", masterErr.String())
	}
	boundPort, err := strconv.Atoi(string(m[1]))
	if err != nil || boundPort < 1 || boundPort > 65535 {
		return fmt.Errorf("could not parse the allocated port (%q): %v", string(m[1]), err)
	}

	// Phase 3: the real, foreground session -- this is the one that
	// triggers fleet-share-serve.
	remoteCmd := fmt.Sprintf("%s %d %d", a.Name, boundPort, int(a.For.Seconds()))
	fmt.Fprintf(os.Stderr, "sharing 127.0.0.1:%d as https://%s.%s ...\n", a.Port, a.Name, shareDomain())
	err = runSSH([]string{"-S", ctrl, "-T", target, remoteCmd}, os.Stdout, os.Stderr)
	return err
}
