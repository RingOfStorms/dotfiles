# Paseo execution environment.
#
# The host-native upstream module is retained in hosts/h001/flake.nix as a
# disabled baseline. This container is the first explicit deployment: Paseo,
# OpenCode, OMP, nono, credentials, and worktrees are scoped to the guest.
{
  constants,
  fleet,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  name = "paseo";
  c = constants.services.paseo;
  net = constants.containerNetwork;
  secretName = "paseo_agent_env_2026-09-21";
  secretHostPath = "${fleet.global.secretsDir}/${secretName}";
  secretContainerPath = "/run/secrets/paseo-agent.env";

  users = {
    users.paseo = {
      isSystemUser = true;
      uid = c.uid;
      group = "paseo";
      home = c.dataDir;
      shell = "${pkgs.bashInteractive}/bin/bash";
    };
    groups.paseo.gid = c.gid;
  };

  binds = [
    {
      host = c.dataDir;
      container = "/var/lib/paseo";
      readOnly = false;
    }
    {
      host = c.projectsDir;
      container = "/srv/paseo-projects";
      readOnly = false;
    }
    {
      host = secretHostPath;
      container = secretContainerPath;
      readOnly = true;
    }
  ];

  bindMounts = lib.listToAttrs (map (bind: {
    name = bind.container;
    value = {
      hostPath = bind.host;
      isReadOnly = bind.readOnly;
    };
  }) binds);

  # Build nono with the pinned rust toolchain used on lio. The upstream source
  # is intentionally a flake=false input because nono does not export a Nix
  # package for this host branch.
  rustPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [ inputs.rust-overlay.overlays.default ];
    config.allowUnfree = true;
  };
  rustToolchain = rustPkgs.rust-bin.stable.latest.default;
  rustPlatform = rustPkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  paseoNono = rustPlatform.buildRustPackage {
    pname = "nono";
    version = inputs.nono.shortRev or inputs.nono.dirtyShortRev or "unknown";
    src = inputs.nono;
    cargoLock.lockFile = "${inputs.nono}/Cargo.lock";
    nativeBuildInputs = with pkgs; [ pkg-config cmake ];
    buildInputs = with pkgs; [ dbus libsecret ];
    cargoBuildFlags = [ "-p" "nono-cli" ];
    cargoTestFlags = [ "-p" "nono-cli" ];
    doCheck = false;
    meta = {
      description = "Secure kernel-enforced sandbox for Paseo providers";
      homepage = "https://github.com/nolabs-ai/nono";
      license = lib.licenses.asl20;
      mainProgram = "nono";
    };
  };

  paseoNonoLauncher = pkgs.writeShellApplication {
    name = "paseo-nono-launch";
    runtimeInputs = [ pkgs.coreutils paseoNono ];
    text = ''
      set -eu
      if [ "''${PASEO_UNSANDBOXED:-0}" = 1 ]; then
        exec "$@"
      fi
      : "''${PASEO_AGENT_CWD:?Paseo did not provide PASEO_AGENT_CWD}"
      exec ${lib.getExe paseoNono} --silent run \
        --profile ${paseoNonoProfile} \
        --workdir "$PASEO_AGENT_CWD" \
        --allow "$PASEO_AGENT_CWD" \
        -- "$@"
    '';
  };

  paseoNonoProfile = pkgs.writeText "paseo-opencode-nono-profile.json" (builtins.toJSON {
    meta = {
      name = "paseo-opencode";
      version = "1";
      description = "Paseo default provider boundary; cwd is granted per launch";
    };
    extends = [ "opencode" ];
    workdir.access = "readwrite";
    environment.allow_vars = [
      "PATH"
      "HOME"
      "USER"
      "LOGNAME"
      "TERM"
      "LANG"
      "LC_*"
      "XDG_*"
      "PASEO_AGENT_*"
      "NO_PROXY"
      "no_proxy"
      "HTTP_PROXY"
      "HTTPS_PROXY"
      "http_proxy"
      "https_proxy"
    ];
  });

  opencode = inputs.opencode.packages.${pkgs.system}.default;
  omp = inputs.omp-flake.packages.${pkgs.system}.default;

  paseoSettings = {
    version = 1;
    daemon = {
      listen = "0.0.0.0:${toString c.port}";
      hostnames = [ c.containerIp constants.host.overlayIp "localhost" ];
      relay.enabled = false;
    };
    app.baseUrl = "http://${c.containerIp}:${toString c.port}";
    worktrees.root = "/srv/paseo-projects";
    pluginsEnabled = false;
    agents.providers = {
      # The patched OpenCode provider creates a dedicated helper generation for
      # each launch context. Both provider commands enter the same per-cwd
      # nono launcher; PASEO_UNSANDBOXED=1 is the deliberate opt-out.
      opencode = {
        enabled = true;
        command = [ "paseo-nono-launch" "opencode" ];
      };
      omp = {
        enabled = true;
        command = [ "paseo-nono-launch" "omp" ];
        params = {
          rpcTimeoutMs = 60000;
          sessionDir = "${c.dataDir}/omp/agent/sessions";
        };
      };
    };
  };
in
{
  inherit users;

  system.activationScripts.createPaseoDirs = ''
    mkdir -p ${c.dataDir} ${c.projectsDir}
    chown ${toString c.uid}:${toString c.gid} ${c.dataDir} ${c.projectsDir}
    chmod 0750 ${c.dataDir} ${c.projectsDir}
  '';

  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = net.hostAddress;
    localAddress = c.containerIp;
    hostAddress6 = net.hostAddress6;
    localAddress6 = c.containerIp6;
    bindMounts = bindMounts;

    config = { pkgs, lib, ... }:
      {
        imports = [ inputs.paseo.nixosModules.paseo ];
        system.stateVersion = "26.05";

        inherit users;
        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [ c.port ];
          };
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;

        environment.systemPackages = with pkgs; [
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
          opencode
          omp
          paseoNono
          paseoNonoLauncher
        ];

        environment.variables = {
          HOME = c.dataDir;
          PASEO_HOME = c.dataDir;
          XDG_CONFIG_HOME = "${c.dataDir}/.config";
          XDG_DATA_HOME = "${c.dataDir}/.local/share";
          XDG_STATE_HOME = "${c.dataDir}/.local/state";
          XDG_CACHE_HOME = "${c.dataDir}/.cache";
          OPENCODE_HOME = "${c.dataDir}/opencode";
          OMP_PROFILE = "paseo";
          NO_PROXY = "127.0.0.1,localhost,${c.containerIp},${constants.host.overlayIp}";
        };

        systemd.tmpfiles.rules = [
          "d ${c.dataDir}/.config 0700 paseo paseo - -"
          "d ${c.dataDir}/.local 0700 paseo paseo - -"
          "d ${c.dataDir}/opencode 0700 paseo paseo - -"
          "d ${c.dataDir}/omp 0700 paseo paseo - -"
          "d ${c.dataDir}/nono 0700 paseo paseo - -"
          "d ${c.dataDir}/runtime 0700 paseo paseo - -"
          "d ${c.projectsDir} 0750 paseo paseo - -"
        ];

        services.paseo = {
          enable = true;
          package = inputs.paseo.packages.${pkgs.system}.paseo;
          user = "paseo";
          group = "paseo";
          dataDir = c.dataDir;
          port = c.port;
          listenAddress = "0.0.0.0";
          openFirewall = false;
          hostnames = [ c.containerIp constants.host.overlayIp ];
          settings = paseoSettings;
          relay.enable = false;
          inheritUserEnvironment = false;
          environment = {
            HOME = c.dataDir;
            PASEO_AGENT_TOOLS = "explicit";
            PASEO_NONO_LAUNCHER = lib.getExe paseoNonoLauncher;
            PASEO_NONO_PROFILE = toString paseoNonoProfile;
            PASEO_NONO_OPTOUT = "PASEO_UNSANDBOXED=1";
          };
          nono.enable = true;
          nono.package = paseoNono;
          nono.profile = paseoNonoProfile;
        };

        # The secret is an operator-populated EnvironmentFile. It must contain
        # PASEO_PASSWORD_BCRYPT and any explicitly provisioned provider keys.
        # The preStart check prevents an accidentally unauthenticated daemon.
        systemd.services.paseo = {
          path = [ pkgs.coreutils pkgs.jq paseoNonoLauncher ];
          serviceConfig = {
            EnvironmentFile = "-${secretContainerPath}";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ c.dataDir c.projectsDir ];
          };
          preStart = lib.mkAfter ''
            test -n "''${PASEO_PASSWORD_BCRYPT:-}" || {
              echo "PASEO_PASSWORD_BCRYPT is required in ${secretContainerPath}" >&2
              exit 1
            }
            tmp=$(mktemp)
            trap 'rm -f "$tmp"' EXIT
            jq --arg password "$PASEO_PASSWORD_BCRYPT" \
              '.daemon.auth.password = $password' \
              ${c.dataDir}/config.json > "$tmp"
            install -m 0600 -o paseo -g paseo "$tmp" ${c.dataDir}/config.json
          '';
        };
      };
  };
}
