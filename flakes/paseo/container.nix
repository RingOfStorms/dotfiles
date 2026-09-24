# Host-side module: declares a private, authenticated Paseo daemon in an
# ephemeral NixOS container. Provider processes (OpenCode, omp) run under
# nono, confined to the agent's worktree.
#
# Only infrastructure is declarative here. Provider and sandbox configs
# (OpenCode, omp, nono profiles) live in the persistent home bind-mounted from
# `dataDir` and are edited by hand; see README.md and examples/.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.paseo;
  inherit (lib) mkOption types;

  # Guest paths. The home is the bind mount of the host's `dataDir`.
  home = "/var/lib/paseo";
  secretPath = "/run/secrets/paseo-agent.env";
  # Provider processes Paseo starts without an agent (catalog refresh and the
  # shared OpenCode server) run here instead of in $HOME, which nono refuses
  # to grant because it contains nono's own state root.
  neutralWorkdir = "${home}/opencode-home";

  proxied = cfg.proxy.domain != null;
  hostnames = [ cfg.containerIp ] ++ lib.optional proxied cfg.proxy.domain ++ cfg.extraHostnames;

  # One definition for host and guest so uid/gid (and thus bind-mount
  # ownership) always match; only the home differs.
  mkUsers = userHome: {
    users.paseo = {
      isSystemUser = true;
      uid = cfg.uid;
      group = "paseo";
      home = userHome;
      shell = "${pkgs.bashInteractive}/bin/bash";
    };
    groups.paseo.gid = cfg.gid;
  };

  # The profile is operator-owned state in the persistent home; its `extends`
  # names resolve against sibling files in the same directory first (e.g. the
  # `opencode` pack policy as opencode.json), so no registry access is needed.
  launcher = pkgs.writeShellApplication {
    name = "paseo-nono-launch";
    runtimeInputs = [ pkgs.coreutils cfg.nonoPackage ];
    text = ''
      if [ "''${PASEO_UNSANDBOXED:-0}" = 1 ]; then
        exec "$@"
      fi
      profile="$HOME/.config/nono/profiles/paseo.json"
      if [ ! -f "$profile" ]; then
        echo "paseo-nono-launch: nono profile not found: $profile" >&2
        echo "paseo-nono-launch: create it from the paseo flake's examples/nono (README: first-time setup), or set PASEO_UNSANDBOXED=1 to run unsandboxed" >&2
        exit 1
      fi
      workdir="''${PASEO_AGENT_CWD:-${neutralWorkdir}}"
      exec ${lib.getExe cfg.nonoPackage} --silent run \
        --profile "$profile" \
        --workdir "$workdir" \
        --allow "$workdir" \
        -- "$@"
    '';
  };

  settings = {
    version = 1;
    features.webUi.enabled = true;
    daemon = {
      listen = "0.0.0.0:${toString cfg.port}";
      hostnames = hostnames ++ [ "localhost" ];
      relay.enabled = false;
    }
    // lib.optionalAttrs proxied {
      # The host reverse proxy connects from hostAddress; trusting it makes
      # the daemon honour X-Forwarded-Proto (the web UI's TLS hint).
      trustedProxies = [ "loopback" cfg.hostAddress ];
      # nginx sends `Host: <domain>:443` (see README), which Paseo's WebSocket
      # same-origin check does not match, so the origin is listed explicitly.
      cors.allowedOrigins = [ "https://${cfg.proxy.domain}" ];
    };
    app.baseUrl =
      if proxied then "https://${cfg.proxy.domain}" else "http://${cfg.containerIp}:${toString cfg.port}";
    worktrees.root = cfg.projectsRoot;
    pluginsEnabled = false;
    # Paseo supplies PASEO_AGENT_CWD in every agent session's launch
    # environment; the launcher uses it as the nono workdir.
    agents.providers = {
      opencode = {
        enabled = true;
        command = [ (lib.getExe launcher) "opencode" ];
      };
    }
    // lib.optionalAttrs (cfg.ompPackage != null) {
      omp = {
        enabled = true;
        command = [ (lib.getExe launcher) "omp" ];
        params.rpcTimeoutMs = 60000;
      };
    };
  };
in
{
  options.ringofstorms.paseo = {
    enable = lib.mkEnableOption "the Paseo container";

    name = mkOption {
      type = types.str;
      default = "paseo";
      description = "Container name (also names the host veth `ve-<name>`).";
    };

    port = mkOption {
      type = types.port;
      default = 6767;
      description = "Daemon port inside the container. Nothing is bound on the host.";
    };

    uid = mkOption {
      type = types.int;
      description = "Pinned uid of the `paseo` user on host and guest (owns the bind mounts).";
    };

    gid = mkOption {
      type = types.int;
      description = "Pinned gid of the `paseo` group on host and guest.";
    };

    containerIp = mkOption {
      type = types.str;
      description = "Container IPv4 address.";
    };

    containerIp6 = mkOption {
      type = types.str;
      description = "Container IPv6 address.";
    };

    hostAddress = mkOption {
      type = types.str;
      description = "Host-side IPv4 address of the container veth.";
    };

    hostAddress6 = mkOption {
      type = types.str;
      description = "Host-side IPv6 address of the container veth.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/paseo";
      description = ''
        Host directory bind-mounted as the guest `paseo` home (/var/lib/paseo):
        Paseo state plus the hand-maintained OpenCode, omp, and nono configs.
      '';
    };

    projectsDir = mkOption {
      type = types.str;
      default = "/var/lib/paseo-projects";
      description = "Host directory holding Paseo's clones and worktrees.";
    };

    projectsRoot = mkOption {
      type = types.str;
      default = "/srv/paseo-projects";
      description = "Guest mount point of `projectsDir`; Paseo's worktree root.";
    };

    secretFile = mkOption {
      type = types.str;
      description = ''
        Host path of the daemon EnvironmentFile, mounted read-only into the
        guest. Must define PASEO_PASSWORD_BCRYPT; may add provider credentials.
      '';
    };

    extraHostnames = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Hostnames/addresses the daemon accepts besides `containerIp`,
        `proxy.domain`, and localhost. Also added to the guest NO_PROXY.
      '';
    };

    proxy.domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "paseo.example.com";
      description = ''
        Public name of an HTTPS reverse proxy on the host in front of the
        daemon (the vhost itself is left to the host). When set, the daemon
        accepts this hostname, trusts `hostAddress` as a proxy, allows the
        `https://<domain>` origin, and uses it as `app.baseUrl`; otherwise
        `app.baseUrl` is `http://<containerIp>:<port>`. The proxy must send
        `Host: <domain>:443` and `X-Forwarded-Proto: https` (README).
      '';
    };

    tailnet = {
      enable = lib.mkEnableOption "tailnet access from the container (masquerade plus a resolved DNS delegate)";
      interface = mkOption {
        type = types.str;
        default = "tailscale0";
        description = "Host tailnet interface the container is masqueraded to.";
      };
      dnsServer = mkOption {
        type = types.str;
        default = "100.100.100.100";
        description = "Tailnet DNS server reached through the host.";
      };
      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "net.example.com" "~example.com" ];
        description = "resolved delegate domains (search and `~` routing domains) for `dnsServer`.";
      };
    };

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.paseo;
      defaultText = lib.literalExpression "paseo.packages.\${system}.paseo";
      description = "Patched Paseo daemon package.";
    };

    # paseo 0.9.0-beta.2 speaks the OpenCode 1.x HTTP API (SDK 1.14.46).
    # OpenCode 2.x serves its web UI on those routes, so every SDK call fails
    # with "Server responded with text/html"; hence nixpkgs' 1.x by default.
    opencodePackage = mkOption {
      type = types.package;
      default = pkgs.opencode;
      defaultText = lib.literalExpression "pkgs.opencode";
      description = "OpenCode package (must speak the 1.x HTTP API).";
    };

    ompPackage = mkOption {
      type = types.nullOr types.package;
      description = "omp package; null disables the omp provider.";
    };

    nonoPackage = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.nono;
      defaultText = lib.literalExpression "paseo.packages.\${system}.nono";
      description = "nono package used by the provider launcher.";
    };

    extraGuestModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      description = "Extra NixOS modules for the guest (e.g. `paseo.lib.toolsModule { ... }`).";
    };

    extraSettings = mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      description = "Merged into the daemon's declarative config.json.";
    };
  };

  config = lib.mkIf cfg.enable {
    users = mkUsers cfg.dataDir;

    system.activationScripts.createPaseoDirs = ''
      mkdir -p ${cfg.dataDir} ${cfg.projectsDir}
      chown ${toString cfg.uid}:${toString cfg.gid} ${cfg.dataDir} ${cfg.projectsDir}
      chmod 0750 ${cfg.dataDir} ${cfg.projectsDir}
    '';

    # Hosts typically masquerade ve-* only out of their LAN interface, so
    # guest packets would reach the tailnet with the container's source
    # address and be dropped. Masquerade just this container to the host's
    # tailnet address; nothing on the tailnet can route back to the container
    # itself, so it stays private.
    networking.nftables.tables."${cfg.name}-tailnet" = lib.mkIf cfg.tailnet.enable {
      family = "inet";
      content = ''
        chain post {
          type nat hook postrouting priority srcnat; policy accept;
          iifname "ve-${cfg.name}" oifname "${cfg.tailnet.interface}" masquerade comment "paseo to tailnet"
        }
      '';
    };

    containers.${cfg.name} = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      inherit (cfg) hostAddress hostAddress6;
      localAddress = cfg.containerIp;
      localAddress6 = cfg.containerIp6;
      bindMounts = {
        ${home} = {
          hostPath = cfg.dataDir;
          isReadOnly = false;
        };
        ${cfg.projectsRoot} = {
          hostPath = cfg.projectsDir;
          isReadOnly = false;
        };
        ${secretPath} = {
          hostPath = cfg.secretFile;
          isReadOnly = true;
        };
      };
      # nspawn's default syscall allow-list omits @sandbox, so landlock_* return
      # EPERM in the guest and nono refuses to run ("Landlock not available").
      extraFlags = [ "--system-call-filter=@sandbox" ];

      config =
        { pkgs, lib, ... }:
        {
          imports = [ self.nixosModules.upstream ] ++ cfg.extraGuestModules;
          system.stateVersion = "26.05";

          users = mkUsers home;
          networking = {
            firewall = {
              enable = true;
              allowedTCPPorts = [ cfg.port ];
            };
            useHostResolvConf = lib.mkForce false;
          };
          # Tailnet names resolve through the host's tailnet DNS server; the
          # delegate is not a default route, so public names keep using the
          # fallback servers.
          services.resolved = {
            enable = true;
            dnsDelegates = lib.mkIf cfg.tailnet.enable {
              tailnet.Delegate = {
                DNS = cfg.tailnet.dnsServer;
                Domains = cfg.tailnet.domains;
              };
            };
          };

          environment.systemPackages =
            (with pkgs; [
              git
              openssh
              jq
              ripgrep
              fd
              fzf
              tree
              curl
              wget
              tmux
              zsh
              bashInteractive
              nodejs
              python3
              rustc
              cargo
            ])
            ++ [ cfg.opencodePackage ]
            ++ lib.optional (cfg.ompPackage != null) cfg.ompPackage
            ++ [
              cfg.nonoPackage
              launcher
            ];

          # Applies to every login/interactive shell (root included). The
          # service sets its own HOME/PASEO_HOME, and the paseo user's passwd
          # home is the same dir, so no HOME/XDG overrides belong here.
          environment.variables.NO_PROXY = lib.concatStringsSep "," ([ "127.0.0.1" "localhost" ] ++ hostnames);

          # Landlock only grants paths that exist, so pre-create every provider
          # path the nono profiles allow. Directories only: the configs inside
          # are operator-owned.
          systemd.tmpfiles.rules =
            map (dir: "d ${home}/${dir} 0700 paseo paseo - -") [
              ".config"
              ".config/opencode"
              ".config/nono"
              ".config/nono/profiles"
              ".cache"
              ".cache/opencode"
              ".local"
              ".local/share"
              ".local/share/opencode"
              ".local/share/opentui"
              ".local/state"
              ".local/state/opencode"
              ".omp"
              ".omp/agent"
              "runtime"
              "opencode-home"
            ]
            ++ [
              # Fixes owner/mode on the host bind mount; uid/gid match (no userns).
              "d ${cfg.projectsRoot} 0750 paseo paseo - -"
            ];

          services.paseo = {
            enable = true;
            inherit (cfg) package port;
            user = "paseo";
            group = "paseo";
            dataDir = home;
            listenAddress = "0.0.0.0";
            openFirewall = false;
            inherit hostnames;
            settings = lib.mkMerge [ settings cfg.extraSettings ];
            relay.enable = false;
            inheritUserEnvironment = false;
            environment = {
              HOME = home;
              PASEO_AGENT_TOOLS = "explicit";
            };
          };

          systemd.services.paseo = {
            # The daemon runs git for clones/worktrees; providers resolve
            # opencode/omp from the PATH nono passes through.
            path =
              [
                pkgs.coreutils
                pkgs.jq
                pkgs.git
                pkgs.openssh
                cfg.opencodePackage
              ]
              ++ lib.optional (cfg.ompPackage != null) cfg.ompPackage;
            serviceConfig = {
              EnvironmentFile = "-${secretPath}";
              UMask = "0077";
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [ home cfg.projectsRoot ];
            };
            # Refuse to start unauthenticated; the hash stays out of the store.
            preStart = lib.mkAfter ''
              test -n "''${PASEO_PASSWORD_BCRYPT:-}" || {
                echo "PASEO_PASSWORD_BCRYPT is required in ${secretPath}" >&2
                exit 1
              }
              tmp=$(mktemp)
              trap 'rm -f "$tmp"' EXIT
              jq --arg password "$PASEO_PASSWORD_BCRYPT" \
                '.daemon.auth.password = $password' \
                ${home}/config.json > "$tmp"
              install -m 0600 -o paseo -g paseo "$tmp" ${home}/config.json
            '';
          };
        };
    };
  };
}
