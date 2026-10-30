{
  description = "fleet-edge - read-only fleet dashboard (ROUTING-PLAN.md §5.2/§5.4)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = rec {
          fleet-edge = pkgs.buildGoModule {
            pname = "fleet-edge";
            version = "0.1.0";
            src = ./.;
            vendorHash = null;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            nativeCheckInputs = [ pkgs.sqlite ];
            postInstall = ''
              wrapProgram $out/bin/fleet-edge --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.sqlite ]}
            '';
            meta = {
              description = "Read-only fleet dashboard: services, routes, host poll status, and metrics";
              mainProgram = "fleet-edge";
            };
          };
          default = fleet-edge;
        };

        apps = rec {
          fleet-edge = {
            type = "app";
            program = "${self.packages.${system}.fleet-edge}/bin/fleet-edge";
          };
          default = fleet-edge;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            gopls
            gotools
          ];
        };
      }
    )
    // {
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.fleet-edge;
          fleetEdgePkg = cfg.package;
        in
        {
          options.services.fleet-edge = {
            enable = lib.mkEnableOption "fleet-edge read-only fleet dashboard";

            listen = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:8099";
              description = ''
                Address the dashboard binds to. Intended to sit behind nginx
                (ROUTING-PLAN.md §5.4: tailnet-only, oauth2-proxy gated);
                never bind to a public address directly.
              '';
            };

            inventoryFile = lib.mkOption {
              type = lib.types.path;
              description = ''
                Path to the inventory JSON, as produced by
                `nix eval --json <containers-flake>#inventory`. Typically
                generated at build time or refreshed by a timer; fleet-edge
                itself only reads this file.
              '';
            };

            statusUrlTemplate = lib.mkOption {
              type = lib.types.str;
              default = "http://{overlayIp}:9101/status.json";
              description = ''
                URL template for each host's status endpoint. `{overlayIp}`,
                `{lanIp}` and `{host}` are substituted per host from the
                inventory. See the fleet-edge README for the JSON contract
                this endpoint must implement.
              '';
            };
            dbPath = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/fleet-edge/metrics.db";
              description = "Path to the SQLite time-series metrics database (empty string disables persistence).";
            };
            geoipCountryFile = lib.mkOption {
              type = lib.types.str;
              default = "";
              example = "/var/lib/fleet-edge/dbip-country-lite.csv.gz";
              description = ''
                Path to an offline DB-IP Lite Country CSV (plain or gzip) used
                to label banned addresses with an IP-registration country.
                Empty disables country lookups. Nothing is downloaded at
                runtime; the file must be provisioned locally.
              '';
            };

            auth = {
              zitadel = {
                enable = lib.mkEnableOption "Zitadel OIDC PKCE authentication";
                issuer = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  example = "https://sso.joshuabell.xyz";
                  description = "Zitadel OIDC issuer URL (empty disables OIDC login).";
                };
                projectId = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  example = "344379162166820867";
                  description = "Zitadel project ID.";
                };
                claim = lib.mkOption {
                  type = lib.types.str;
                  default = "flatRolesClaim";
                  description = "Zitadel JWT claim containing flat role names.";
                };
                clientId = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Zitadel OIDC PKCE application client ID.";
                };
                redirectUri = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  example = "https://fleet.joshuabell.xyz/auth/callback";
                  description = "Zitadel OIDC callback URL (auto-derived from request Host if empty).";
                };
                allowedRole = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Required Zitadel role (empty allows any authenticated user of the project).";
                };
              };
              apiKeysFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "/var/lib/secrets_manager_hydrated/fleet-edge-api-keys";
                description = "Path to newline-delimited plain API keys for Authorization: Bearer <key> or X-API-Key: <key>.";
              };
              sessionKeyFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional path to HMAC session signing key file.";
              };
            };

            overrides = {
              enable = lib.mkEnableOption ''
                the public `cnt expose` authority and the placement registry
                (fleet-edge-overrides, own unit and state);
                see containers/PLACEMENT-PLAN.md
              '';
              listen = lib.mkOption {
                type = lib.types.str;
                default = "127.0.0.1:8098";
                description = "Loopback address h005 nginx proxies /api/overrides and /api/placements to.";
              };
              specFile = lib.mkOption {
                type = lib.types.path;
                description = "Public DNS spec JSON (the same file dns-plan reads).";
              };
              target = lib.mkOption {
                type = lib.types.str;
                example = "o002.joshuabell.xyz";
                description = "CNAME target for override records.";
              };
              dns = {
                tailnetDir = lib.mkOption { type = lib.types.str; default = "/var/lib/fleet-edge-dns/tailnet"; };
                lanDir = lib.mkOption { type = lib.types.str; default = "/var/lib/fleet-edge-dns/lan"; };
                tailnetServer = lib.mkOption { type = lib.types.str; default = ""; description = "Tailnet dnsmasq IP:port for routing audit."; };
                lanServer = lib.mkOption { type = lib.types.str; default = "127.0.0.1:9053"; };
              };
              zitadel = {
                issuer = lib.mkOption {
                  type = lib.types.str;
                  example = "https://sso.joshuabell.xyz";
                  description = "Issuer of the writers' machine tokens (the sec-agent login).";
                };
                projectId = lib.mkOption {
                  type = lib.types.str;
                  example = "344379162166820867";
                  description = "Project the machine tokens' audience must include (sec-agent's projectId).";
                };
              };
              writers = lib.mkOption {
                default = { };
                description = ''
                  Hosts allowed to write, keyed by host name: a request needs a
                  valid Zitadel token whose sub is the host's machine user AND
                  must come from the host's overlay IP. Roles/trust are ignored.
                '';
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options = {
                      sub = lib.mkOption { type = lib.types.strMatching "[0-9]+"; };
                      peer = lib.mkOption { type = lib.types.str; };
                    };
                  }
                );
              };
              bunnyKeyFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "bunny API key (LoadCredential). Both keys null = writes return 503.";
              };
              pushKeyFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "ssh key for the edge's fleet-vhost-receive (LoadCredential).";
              };
              pushTarget = lib.mkOption {
                type = lib.types.str;
                default = "";
                example = "root@o002";
              };
              knownHosts = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "known_hosts lines for pushTarget.";
              };
            };

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              description = "fleet-edge package to run.";
            };

            title = lib.mkOption {
              type = lib.types.str;
              default = "fleet-edge";
              description = "Page title shown in the nav bar and browser tab.";
            };

            background = lib.mkOption {
              type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
              default = null;
              example = "https://w.wallhaven.cc/full/k9/wallhaven-k912lq.png";
              description = ''
                Background image. An http(s) URL is used directly by the
                browser; anything else is a local file served at /assets/bg
                (a Nix path is copied into the store; a string path must be
                readable by the sandboxed DynamicUser, i.e. not under /home).
                Passed as FLEET_EDGE_BACKGROUND.
              '';
            };

            iconBase = lib.mkOption {
              type = lib.types.str;
              default = "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/{name}.svg";
              description = ''
                CDN template for named icons; `{name}` is replaced by the icon
                name. Icons that are full URLs are used as-is; tiles without
                an icon (or whose icon fails to load) show their first letter.
              '';
            };

            links = lib.mkOption {
              default = [ ];
              description = ''
                Start-page entries that aren't container routes (or that
                override a route's tile: a link whose url matches an inventory
                route url takes its place and shows its polled state). Groups
                are rendered in order of first appearance; unclaimed inventory
                routes follow under their route `group` ("Fleet services" if unset).
              '';
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    name = lib.mkOption { type = lib.types.str; };
                    url = lib.mkOption { type = lib.types.str; };
                    icon = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                      description = "Icon URL or CDN icon name; empty for the letter fallback.";
                    };
                    group = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                    };
                    description = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                    };
                    host = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                      description = ''
                        Fleet host serving this link. Ignored when the url
                        matches an inventory route (the route's host wins);
                        empty means infer from the url.
                      '';
                    };
                    exposure = lib.mkOption {
                      type = lib.types.enum [
                        ""
                        "public"
                        "tailnet"
                        "lan"
                        "local"
                      ];
                      default = "";
                      description = ''
                        Exposure badge for this link. Ignored when the url
                        matches an inventory route (the route's exposure wins);
                        empty shows no badge.
                      '';
                    };
                  };
                }
              );
            };

            topology = lib.mkOption {
              type = lib.types.nullOr lib.types.json;
              default = null;
              description = ''
                /topology diagram spec, passed as FLEET_EDGE_TOPOLOGY. The
                schema is `topology.Spec` in internal/topology/topology.go:
                width, height, columns[]{id,label,flex,zones[]{id,label,
                kind,flex,layout,cols,fill,box,group}}, nodes[]{id,host,
                label,kind,zone,segment,role,badges[],lines[],href},
                links[]{from,to,kind,label}, dns{zone,records[]{name,type,
                value,ttl,external},external[]}, defaultZone, hide[] and
                hubs{tailnet,edge,router,dashboard}. A column owns a share of
                the width and its own height; a zone inside it owns a share of
                that column's leftover. Hosts, container placement, public
                paths, tailnet membership and agent polling are derived from
                the inventory, so the spec only carries what the inventory
                cannot know. Host bindings and every reference are validated at
                startup. null keeps the built-in single-zone diagram.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            # Ensure /var/lib/private is 0700 even when Impermanence pre-creates
            # parent directories with 0755 for /var/lib/private/fleet-edge.
            systemd.tmpfiles.rules = [
              "z /var/lib/private 0700 root root -"
              # Shared flock for dns-plan --apply and fleet-edge-overrides.
              "d /run/fleet-edge-bunny 1777 root root -"
            ] ++ lib.optionals cfg.overrides.enable [
              "d ${cfg.overrides.dns.tailnetDir} 0775 root fleet-edge-dns -"
              "d ${cfg.overrides.dns.lanDir} 0775 root fleet-edge-dns -"
            ];
            users.groups.fleet-edge-dns = lib.mkIf cfg.overrides.enable { };

            systemd.services.fleet-edge-overrides = lib.mkIf cfg.overrides.enable (
              let
                o = cfg.overrides;
                live = o.bunnyKeyFile != null && o.pushKeyFile != null;
                writers = pkgs.writeText "fleet-edge-writers.json" (builtins.toJSON o.writers);
                knownHosts = pkgs.writeText "fleet-edge-edge-known-hosts" o.knownHosts;
              in
              {
                description = "fleet-edge expose overrides and placement registry (ROUTING-PLAN §8 step 7)";
                wantedBy = [ "multi-user.target" ];
                after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
                wants = [ "network-online.target" ];
                path = [ pkgs.openssh ];
                serviceConfig = {
                  ExecStart = lib.concatStringsSep " " (
                    [
                      (lib.getExe fleetEdgePkg)
                      "overrides"
                      "--listen ${o.listen}"
                      "--inventory ${cfg.inventoryFile}"
                      "--spec ${o.specFile}"
                      "--writers ${writers}"
                      "--zitadel-issuer ${lib.escapeShellArg o.zitadel.issuer}"
                      "--zitadel-project-id ${lib.escapeShellArg o.zitadel.projectId}"
                      "--target ${lib.escapeShellArg o.target}"
                      "--status-url-template ${lib.escapeShellArg cfg.statusUrlTemplate}"
                      "--dns-tailnet-dir ${lib.escapeShellArg o.dns.tailnetDir}"
                      "--dns-lan-dir ${lib.escapeShellArg o.dns.lanDir}"
                      "--dns-tailnet-server ${lib.escapeShellArg o.dns.tailnetServer}"
                      "--dns-lan-server ${lib.escapeShellArg o.dns.lanServer}"
                    ]
                    ++ lib.optionals live [
                      "--bunny-key-file %d/bunny"
                      "--push-key-file %d/push"
                      "--push-target ${lib.escapeShellArg o.pushTarget}"
                      "--known-hosts ${knownHosts}"
                    ]
                  );
                  LoadCredential = lib.optionals live [
                    "bunny:${o.bunnyKeyFile}"
                    "push:${o.pushKeyFile}"
                  ];
                  Restart = "on-failure";
                  RestartSec = "5s";
                  StateDirectory = "fleet-edge-overrides";
                  StateDirectoryMode = "0700";
                  ReadWritePaths = [ "/run/fleet-edge-bunny" o.dns.tailnetDir o.dns.lanDir ];
                  SupplementaryGroups = [ "fleet-edge-dns" ];
                  DynamicUser = true;
                  UMask = "0077";
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  PrivateTmp = true;
                  PrivateDevices = true;
                  ProtectKernelTunables = true;
                  ProtectKernelModules = true;
                  ProtectKernelLogs = true;
                  ProtectControlGroups = true;
                  ProtectClock = true;
                  ProtectHostname = true;
                  ProtectProc = "invisible";
                  ProcSubset = "pid";
                  RestrictNamespaces = true;
                  RestrictRealtime = true;
                  RestrictSUIDSGID = true;
                  LockPersonality = true;
                  MemoryDenyWriteExecute = true;
                  RemoveIPC = true;
                  CapabilityBoundingSet = [ "" ];
                  AmbientCapabilities = [ "" ];
                  SystemCallFilter = [ "@system-service" ];
                  SystemCallErrorNumber = "EPERM";
                  SystemCallArchitectures = "native";
                  RestrictAddressFamilies = [
                    "AF_INET"
                    "AF_INET6"
                    "AF_UNIX"
                  ];
                };
              }
            );

            systemd.services.fleet-edge = {
              description = "fleet-edge read-only dashboard";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];

              environment = {
                FLEET_EDGE_TITLE = cfg.title;
                FLEET_EDGE_ICON_BASE = cfg.iconBase;
                FLEET_EDGE_LINKS = toString (pkgs.writeText "fleet-edge-links.json" (builtins.toJSON cfg.links));
                FLEET_EDGE_DB = cfg.dbPath;
                FLEET_EDGE_GEOIP_COUNTRY_FILE = cfg.geoipCountryFile;
                FLEET_EDGE_ZITADEL_ISSUER = if cfg.auth.zitadel.enable then cfg.auth.zitadel.issuer else "";
                FLEET_EDGE_ZITADEL_PROJECT_ID = if cfg.auth.zitadel.enable then cfg.auth.zitadel.projectId else "";
                FLEET_EDGE_ZITADEL_CLAIM = cfg.auth.zitadel.claim;
                FLEET_EDGE_ZITADEL_CLIENT_ID = if cfg.auth.zitadel.enable then cfg.auth.zitadel.clientId else "";
                FLEET_EDGE_ZITADEL_REDIRECT_URI = cfg.auth.zitadel.redirectUri;
                FLEET_EDGE_ZITADEL_ROLE = cfg.auth.zitadel.allowedRole;
              }
              // lib.optionalAttrs (cfg.background != null) {
                FLEET_EDGE_BACKGROUND =
                  if builtins.isPath cfg.background then "${cfg.background}" else cfg.background;
              }
              // lib.optionalAttrs cfg.overrides.enable {
                # Read-only loopback export; the dashboard holds no token or key.
                FLEET_EDGE_OVERRIDES_URL = "http://${cfg.overrides.listen}/internal/overrides.json";
              }
              // lib.optionalAttrs (cfg.auth.apiKeysFile != null) {
                FLEET_EDGE_API_KEYS_FILE = cfg.auth.apiKeysFile;
              }
              // lib.optionalAttrs (cfg.auth.sessionKeyFile != null) {
                FLEET_EDGE_SESSION_KEY_FILE = cfg.auth.sessionKeyFile;
              }
              // lib.optionalAttrs (cfg.topology != null) {
                FLEET_EDGE_TOPOLOGY = toString (
                  pkgs.writeText "fleet-edge-topology.json" (builtins.toJSON cfg.topology)
                );
              };

              serviceConfig = {
                ExecStart = ''
                  ${lib.getExe fleetEdgePkg} \
                    --listen ${cfg.listen} \
                    --inventory ${cfg.inventoryFile} \
                    --status-url-template ${lib.escapeShellArg cfg.statusUrlTemplate}
                '';
                Restart = "on-failure";
                RestartSec = "5s";

                StateDirectory = "fleet-edge";
                StateDirectoryMode = "0750";

                DynamicUser = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectKernelLogs = true;
                ProtectControlGroups = true;
                ProtectClock = true;
                ProtectHostname = true;
                ProtectProc = "invisible";
                ProcSubset = "pid";
                RestrictNamespaces = true;
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                LockPersonality = true;
                MemoryDenyWriteExecute = true;
                RemoveIPC = true;
                UMask = "0077";
                CapabilityBoundingSet = [ "" ];
                AmbientCapabilities = [ "" ];
                SystemCallFilter = [ "@system-service" ];
                SystemCallErrorNumber = "EPERM";
                SystemCallArchitectures = "native";
                RestrictAddressFamilies = [
                  "AF_INET"
                  "AF_INET6"
                  "AF_UNIX"
                ];
              };
            };
          };
        };
    };
}
