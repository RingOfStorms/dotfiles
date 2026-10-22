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
            meta = {
              description = "Read-only fleet dashboard: services, routes, host poll status";
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
          };

          config = lib.mkIf cfg.enable {
            systemd.services.fleet-edge = {
              description = "fleet-edge read-only dashboard";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];

              environment = {
                FLEET_EDGE_TITLE = cfg.title;
                FLEET_EDGE_ICON_BASE = cfg.iconBase;
                FLEET_EDGE_LINKS = toString (pkgs.writeText "fleet-edge-links.json" (builtins.toJSON cfg.links));
              }
              // lib.optionalAttrs (cfg.background != null) {
                FLEET_EDGE_BACKGROUND =
                  if builtins.isPath cfg.background then "${cfg.background}" else cfg.background;
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

                # Sandboxing: read-only dashboard, no reason to touch disk
                # beyond reading the inventory file, or escalate privilege.
                DynamicUser = true;
                NoNewPrivileges = true;
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
