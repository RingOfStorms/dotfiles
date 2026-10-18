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
          };

          config = lib.mkIf cfg.enable {
            systemd.services.fleet-edge = {
              description = "fleet-edge read-only dashboard";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];

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
