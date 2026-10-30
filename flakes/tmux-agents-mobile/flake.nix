{
  description = "tmux-agents-mobile: a phone-sized view of tmux agent panes, without attaching a client";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # The plugin provides `rows --json` (the repo/worktree/agent tree) and the
    # tick that publishes @agent_state / @agent_unseen / @agent_win.
    tmux-agents.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/tmux-agents";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      tmux-agents,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        plugin = tmux-agents.lib.mkPlugin pkgs;
        # Same nixpkgs as `programs.tmux`, so the client protocol matches the
        # running server after a rebuild.
        agentsBin = "${plugin}/share/tmux-plugins/tmux-agents/bin/tmux-agents";
      in
      {
        # buildGo127Module pins the toolchain to nixpkgs' go_1_27 (1.27.3)
        # instead of the default `go`, so the go.mod directive below can track
        # the newest language version without depending on which go nixpkgs
        # currently makes the default.
        packages.default = pkgs.buildGo127Module {
          pname = "tmux-agents-mobile";
          version = "0.1.0";
          src = ./.;
          vendorHash = "sha256-8zBX8NEzRfduIYJ2QZMSMwlCUlQaPGxzRfcB6zMhtuc=";
          nativeBuildInputs = [ pkgs.makeWrapper ];
          # The tmux integration tests start an isolated `tmux -L tamtest-…`
          # server; tmux must be on PATH inside the sandbox, and it needs a
          # shell that exists there (the sandbox has no login shell of its own).
          # The tmux integration tests also shell out to git (repo/branch
          # lookups in the no-plugin fallback).
          nativeCheckInputs = [
            pkgs.tmux
            pkgs.git
          ]
          # The transcript locator tests walk the process tree with ps.
          ++ lib.optional pkgs.stdenv.isLinux pkgs.procps;
          preCheck = ''
            export SHELL=${pkgs.bashInteractive}/bin/bash
            export TMUX_TMPDIR="$TMPDIR"
            # tmux starts sessions in $HOME; the build sandbox home does not
            # exist, and a shell that cannot start takes the server with it.
            export HOME="$TMPDIR"
          '';
          postInstall = ''
            wrapProgram $out/bin/tmux-agents-mobile \
              --suffix PATH : ${
                lib.makeBinPath (
                  [
                    pkgs.tmux
                    pkgs.git
                    pkgs.fzf
                  ]
                  # ps: the native view walks the pane's process tree to find
                  # the agent (macOS has /bin/ps).
                  ++ lib.optional pkgs.stdenv.isLinux pkgs.procps
                )
              } \
              --set-default TAM_TMUX ${pkgs.tmux}/bin/tmux \
              --set-default TAM_AGENTS ${agentsBin}
          '';
          meta = {
            description = "Mobile check-in UI for tmux agent panes";
            mainProgram = "tmux-agents-mobile";
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/tmux-agents-mobile";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go_1_27
            gopls
            gotools
            tmux
            git
          ];
        };
      }
    )
    // {
      # NixOS: the UI runs as a systemd *user* unit. It must be the same user as
      # the tmux server to reach /tmp/tmux-<uid>/default without loosening a
      # system unit's sandbox; NixOS installs user units system-wide, so
      # ConditionUser pins it to the configured account. This module only runs
      # the app - the vhost, firewall and DNS belong to the host.
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.tmux-agents-mobile;
          environment = import ./nix/environment.nix { inherit cfg lib; };
        in
        {
          imports = [ ./nix/options.nix ];

          config = lib.mkIf cfg.enable {
            services.tmux-agents-mobile.package =
              lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;

            systemd.user.services.tmux-agents-mobile = {
              description = "tmux-agents-mobile phone UI";
              wantedBy = [ "default.target" ];
              after = [ "network.target" ];
              # A unit-level directive: the account that owns the tmux server.
              unitConfig.ConditionUser = cfg.user;
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/tmux-agents-mobile";
                Restart = "on-failure";
                RestartSec = "5s";
                UMask = "0077";
                Environment = lib.mapAttrsToList (name: value: "${name}=${value}") environment;
                # A user unit cannot carry most systemd hardening (no
                # capabilities, no namespaces); these two still apply.
                NoNewPrivileges = true;
                RestrictSUIDSGID = true;
              };
            };
          };
        };

      # nix-darwin: the same service as a per-user launchd agent.
      darwinModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.tmux-agents-mobile;
          environment = import ./nix/environment.nix { inherit cfg lib; };
        in
        {
          imports = [ ./nix/options.nix ];

          config = lib.mkIf cfg.enable {
            services.tmux-agents-mobile.package =
              lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;

            launchd.user.agents.tmux-agents-mobile = {
              command = "${cfg.package}/bin/tmux-agents-mobile";
              serviceConfig = {
                RunAtLoad = true;
                KeepAlive = true;
                EnvironmentVariables = environment;
              };
            };
          };
        };

      # Runs as the same user as the tmux server (so the socket needs no
      # tricks) and is meant to sit behind nginx on a tailnet-only vhost. The
      # Zitadel client is configured through the environment; see README.md.
      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.tmux-agents-mobile;
        in
        {
          options.services.tmux-agents-mobile = {
            enable = lib.mkEnableOption "the tmux-agents-mobile web UI";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              description = "tmux-agents-mobile package to run.";
            };

            listen = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:8099";
              description = ''
                Address the UI binds to. Keep it on loopback: nginx terminates
                the tailnet vhost and proxies here.
              '';
            };

            healthListen = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:8098";
              description = "Loopback-only /healthz listener; empty string disables it.";
            };

            roots = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "~/projects"
                "~/other"
                "~/.config"
                "~/.local/share/git_worktrees"
              ];
              description = ''
                Directories a new session may be created in. Anything outside
                them is rejected by the form.
              '';
            };

            environmentFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              example = "/run/secrets/tmux-agents-mobile.env";
              description = ''
                File with TAM_ZITADEL_* / TAM_SESSION_KEY_FILE. Keep it out of
                the Nix store.
              '';
            };

            extraEnvironment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Extra environment variables for the service.";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.user.services.tmux-agents-mobile = {
              Unit = {
                Description = "tmux-agents-mobile web UI";
                After = [ "network.target" ];
              };
              Install.WantedBy = [ "default.target" ];
              Service = {
                ExecStart = "${cfg.package}/bin/tmux-agents-mobile";
                Restart = "on-failure";
                RestartSec = "5s";
                UMask = "0077";

                Environment = {
                  TAM_LISTEN = cfg.listen;
                  TAM_HEALTH_LISTEN = cfg.healthListen;
                  TAM_ROOTS = lib.concatStringsSep ":" cfg.roots;
                }
                // cfg.extraEnvironment;

                # Deliberately light sandboxing: this process must reach the
                # user's tmux socket (/tmp/tmux-<uid>/) and run git in
                # ~/projects, so PrivateTmp and ProtectHome would break it.
                NoNewPrivileges = true;
                RestrictSUIDSGID = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictNamespaces = true;
                LockPersonality = true;
              };
            }
            // lib.optionalAttrs (cfg.environmentFile != null) {
              EnvironmentFile = cfg.environmentFile;
            };
          };
        };
    };
}
