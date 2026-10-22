// Command fleet-edge serves the read-only fleet dashboard described in
// containers/ROUTING-PLAN.md §5.2 and §5.4: a start page of app tiles
// (inventory routes plus configured links), a table of every service
// (declared vs. polled state, routes, description) and a per-host poll
// status page, backed by the static inventory plus each host's status
// endpoint (contract documented in internal/state).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/auth"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/bunny"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/dash"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/inventory"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/server"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/state"
	"git.joshuabell.xyz/ringofstorms/fleet-edge/internal/store"
)

// envDefault returns $key if set, else def; flags still override.
func envDefault(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

// dnsPlan: `fleet-edge dns-plan --spec records.json --key-file f [--apply]`.
// Fetches the zone and prints what a reconcile would do (ROUTING-PLAN §8
// step 4). With --apply it then executes only the create/update/retire rows
// (refusing the whole plan on any conflict or retire-mismatch).
func dnsPlan(args []string) {
	fs := flag.NewFlagSet("dns-plan", flag.ExitOnError)
	specFile := fs.String("spec", "", "desired records JSON (generated on h005)")
	keyFile := fs.String("key-file", "", "file holding the bunny API key")
	zoneFile := fs.String("zone-json", "", "use this saved zone JSON instead of the API (offline)")
	apply := fs.Bool("apply", false, "execute creates, updates and exact-match retires")
	_ = fs.Parse(args)
	var client *bunny.Client
	spec, err := bunny.LoadSpec(*specFile)
	if err != nil {
		log.Fatal(err)
	}
	var z *bunny.Zone
	if *zoneFile != "" {
		b, err := os.ReadFile(*zoneFile)
		if err != nil {
			log.Fatal(err)
		}
		z = &bunny.Zone{}
		if err := json.Unmarshal(b, z); err != nil {
			log.Fatal(err)
		}
	} else {
		key, err := os.ReadFile(*keyFile)
		if err != nil {
			log.Fatal(err)
		}
		client = &bunny.Client{Key: strings.TrimSpace(string(key))}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		z, err = client.ZoneByDomain(ctx, spec.Zone)
		if err != nil {
			log.Fatal(err)
		}
	}
	plan := bunny.Plan(spec, z)
	bunny.Render(os.Stdout, spec.Zone, plan)
	ops, err := bunny.Ops(z.ID, plan)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("\n%d operations:\n", len(ops))
	for _, op := range ops {
		fmt.Printf("  %-6s %s  (%s %s %s)\n", op.Method, op.Path, op.Change.Action, op.Change.Name, op.Change.Type)
	}
	if !*apply {
		fmt.Println("dry run; pass --apply to execute")
		return
	}
	if client == nil {
		log.Fatal("--apply needs the API (no --zone-json)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	err = client.Apply(ctx, ops, func(op bunny.Op) { fmt.Printf("done   %s %s\n", op.Method, op.Path) })
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("applied %d operations\n", len(ops))
}

// importBeszel: `fleet-edge import-beszel --beszel-db /path/to/data.db --db /var/lib/fleet-edge/metrics.db [--map h002=h004]`.
func importBeszel(args []string) {
	fs := flag.NewFlagSet("import-beszel", flag.ExitOnError)
	beszelDB := fs.String("beszel-db", "", "path to Beszel PocketBase data.db")
	targetDB := fs.String("db", "/var/lib/fleet-edge/metrics.db", "path to fleet-edge SQLite metrics.db")
	mapSpec := fs.String("map", "h002=h004", "comma-separated old=new host mappings (e.g. h002=h004)")
	_ = fs.Parse(args)
	if *beszelDB == "" {
		log.Fatal("--beszel-db is required")
	}
	hostMap := map[string]string{}
	for _, pair := range strings.Split(*mapSpec, ",") {
		if oldH, newH, ok := strings.Cut(strings.TrimSpace(pair), "="); ok && oldH != "" && newH != "" {
			hostMap[strings.TrimSpace(oldH)] = strings.TrimSpace(newH)
		}
	}
	st, err := store.Open(*targetDB)
	if err != nil {
		log.Fatalf("open store %s: %v", *targetDB, err)
	}
	n, err := st.ImportBeszel(context.Background(), *beszelDB, hostMap)
	if err != nil {
		log.Fatalf("import-beszel: %v", err)
	}
	fmt.Printf("imported %d Beszel stat rows into %s (mappings: %v)\n", n, *targetDB, hostMap)
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "dns-plan":
			dnsPlan(os.Args[2:])
			return
		case "import-beszel":
			importBeszel(os.Args[2:])
			return
		}
	}
	listen := flag.String("listen", "127.0.0.1:8099", "address to bind the HTTP server to")
	inventoryFile := flag.String("inventory", "", "path to inventory JSON (nix eval --json <containers-flake>#inventory)")
	statusURLTemplate := flag.String("status-url-template", "http://{overlayIp}:9101/status.json",
		"per-host status endpoint URL template; {overlayIp}, {lanIp} and {host} are substituted")
	pollInterval := flag.Duration("poll-interval", 30*time.Second, "how often to poll each host's status endpoint")
	pollTimeout := flag.Duration("poll-timeout", 3*time.Second, "per-host poll timeout")
	dbPath := flag.String("db", envDefault("FLEET_EDGE_DB", ""), "path to SQLite metrics database (empty disables persistence)")
	title := flag.String("title", envDefault("FLEET_EDGE_TITLE", "fleet-edge"), "page title (env FLEET_EDGE_TITLE)")
	background := flag.String("background", envDefault("FLEET_EDGE_BACKGROUND", ""),
		"background image: http(s) URL used directly, or a local file served at /assets/bg (env FLEET_EDGE_BACKGROUND)")
	iconBase := flag.String("icon-base", envDefault("FLEET_EDGE_ICON_BASE", dash.DefaultIconBase),
		"CDN template for named icons, {name} substituted (env FLEET_EDGE_ICON_BASE)")
	linksFile := flag.String("links", envDefault("FLEET_EDGE_LINKS", ""),
		"JSON array of extra start-page links [{name,url,icon,group,description,host,exposure}] (env FLEET_EDGE_LINKS)")
	zitadelIssuer := flag.String("zitadel-issuer", envDefault("FLEET_EDGE_ZITADEL_ISSUER", ""), "Zitadel OIDC issuer URL")
	zitadelProjectID := flag.String("zitadel-project-id", envDefault("FLEET_EDGE_ZITADEL_PROJECT_ID", ""), "Zitadel project ID")
	zitadelClaim := flag.String("zitadel-claim", envDefault("FLEET_EDGE_ZITADEL_CLAIM", "flatRolesClaim"), "Zitadel roles claim")
	zitadelClientID := flag.String("zitadel-client-id", envDefault("FLEET_EDGE_ZITADEL_CLIENT_ID", ""), "Zitadel OIDC client ID")
	zitadelRedirectURI := flag.String("zitadel-redirect-uri", envDefault("FLEET_EDGE_ZITADEL_REDIRECT_URI", ""), "Zitadel OIDC redirect URI")
	zitadelRole := flag.String("zitadel-role", envDefault("FLEET_EDGE_ZITADEL_ROLE", ""), "required Zitadel role (empty allows any project user)")
	apiKeysFile := flag.String("api-keys-file", envDefault("FLEET_EDGE_API_KEYS_FILE", ""), "file holding newline-delimited plain API keys")
	sessionKeyFile := flag.String("session-key-file", envDefault("FLEET_EDGE_SESSION_KEY_FILE", ""), "file holding HMAC session key (optional)")
	flag.Parse()

	if *inventoryFile == "" {
		log.Fatal("--inventory is required")
	}

	inv, err := inventory.Load(*inventoryFile)
	if err != nil {
		log.Fatalf("loading inventory: %v", err)
	}
	links, err := dash.LoadLinks(*linksFile)
	if err != nil {
		log.Fatalf("loading links: %v", err)
	}
	if bg := *background; bg != "" && !strings.HasPrefix(bg, "http://") && !strings.HasPrefix(bg, "https://") {
		if _, err := os.Stat(*background); err != nil {
			log.Fatalf("background: %v", err)
		}
	}

	poller := state.NewPoller(inv, *statusURLTemplate, *pollTimeout)
	if *dbPath != "" {
		st, err := store.Open(*dbPath)
		if err != nil {
			log.Fatalf("opening metrics db %s: %v", *dbPath, err)
		}
		poller.SetStore(st)
	}

	var sessionSecret []byte
	if *sessionKeyFile != "" {
		b, err := os.ReadFile(*sessionKeyFile)
		if err != nil {
			log.Fatalf("reading session-key-file %s: %v", *sessionKeyFile, err)
		}
		sessionSecret = []byte(strings.TrimSpace(string(b)))
	}
	authn, err := auth.New(auth.Config{
		Zitadel: auth.ZitadelConfig{
			Issuer:      *zitadelIssuer,
			ProjectID:   *zitadelProjectID,
			Claim:       *zitadelClaim,
			ClientID:    *zitadelClientID,
			RedirectURI: *zitadelRedirectURI,
			AllowedRole: *zitadelRole,
		},
		APIKeysFile:   *apiKeysFile,
		SessionSecret: sessionSecret,
	})
	if err != nil {
		log.Fatalf("configuring auth: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	go poller.Run(ctx, *pollInterval)

	srv := server.New(poller, server.Config{
		Title:      *title,
		Background: *background,
		IconBase:   *iconBase,
		Links:      links,
	})
	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           authn.Wrap(srv),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("fleet-edge listening on %s (inventory=%s, links=%d)", *listen, *inventoryFile, len(links))
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}
