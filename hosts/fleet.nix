# Fleet Registry + Host Builder
#
# Single source of truth for fleet-wide constants, per-host metadata,
# and a `mkHost` builder that eliminates per-host boilerplate.
#
# Usage in a host's flake.nix:
#
#   let
#     fleet = import ../fleet.nix;          # adjust relative path as needed
#     constants = import ./_constants.nix;
#   in {
#     nixosConfigurations.${constants.host.name} = fleet.mkHost {
#       inherit inputs constants;
#       secretsRole = "machines-hightrust";
#       nixosModules = [ ... ];             # host-specific modules
#       hmModules = [ ... ];                # extra HM shared modules
#     };
#   };
#
rec {
  # ─── GLOBAL CONSTANTS ─────────────────────────────────────────────
  global = {
    domain = "joshuabell.xyz";
    acmeEmail = "admin@joshuabell.xyz";

    # SSH public key used across all hosts for authorized_keys
    sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15";
    sshKeyName = "nix2nix_2026-03-15";
    secretsKeyPath = "/var/lib/openbao-secrets/nix2nix_2026-03-15";

    openbaoAddr = "https://sec.joshuabell.xyz";
    gitUrl = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles";
  };

  # ─── PER-HOST REGISTRY ────────────────────────────────────────────
  # Every host that appears in SSH configs, deploy scripts, or is referenced
  # by other hosts should be registered here.
  #
  # Fields:
  #   user        - primary SSH user (required)
  #   overlayIp   - Tailscale overlay IP (null if not on tailnet)
  #   lanIp       - LAN IP address (null if not on LAN / cloud host)
  #   publicIp    - Public IP (for cloud/VPS hosts)
  #   trust       - "high" | "low" | "none" (determines secrets-bao role)
  #   flakePath   - path to host's flake dir relative to repo root (auto-derived from name if omitted)
  #   sshTermEnv  - custom TERM for SSH (null for default xterm-256color)
  hosts = {
    h001 = {
      user = "luser";
      overlayIp = "100.64.0.13";
      lanIp = "10.12.14.10";
      trust = "high";
    };
    h002 = {
      user = "luser";
      overlayIp = "100.64.0.3";
      lanIp = "10.12.14.183";
      trust = "high";
    };
    h003 = {
      user = "luser";
      overlayIp = "100.64.0.14";
      lanIp = "10.12.14.1";
      trust = "high";
    };
    i001 = {
      user = "luser";
      lanIp = "10.12.14.119";
      trust = "low";
    };
    joe = {
      user = "josh";
      overlayIp = "100.64.0.12";
      lanIp = "10.12.14.126";
      trust = "low";
    };
    juni = {
      user = "josh";
      overlayIp = "100.64.0.18";
      lanIp = "10.12.14.172";
      trust = "high";
    };
    lio = {
      user = "josh";
      overlayIp = "100.64.0.1";
      lanIp = "10.12.14.116";
      trust = "high";
    };
    oren = {
      user = "josh";
      overlayIp = "100.64.0.2";
      trust = "high";
    };
    gp3 = {
      user = "luser";
      overlayIp = "100.64.0.15";
      lanIp = "10.12.14.144";
      trust = "low";
    };
    o002 = {
      user = "root";
      overlayIp = "100.64.0.5";
      publicIp = "164.152.19.60";
      trust = "high";
      flakePath = "hosts/oracle/o002";
    };
    # Non-deployable hosts referenced in SSH configs
    t = {
      user = "joshua.bell";
      lanIp = "10.12.14.181";
      sshTermEnv = "vt100";
    };
    l002 = {
      user = "root";
      publicIp = "172.234.26.141";
    };
  };

  # ─── DEPLOY TARGETS ───────────────────────────────────────────────
  # Hosts that can be deployed to from the root flake devShell.
  deployableHosts = builtins.removeAttrs hosts [ "t" "l002" ];

  # ─── SSH MATCH BLOCK HOSTS ────────────────────────────────────────
  # Used by secrets-bao mkAutoSecrets to wire nix2nix identity.
  # Generates the list of all SSH matchBlock host names (including _ variants).
  # An `_` variant is emitted for any host with a direct IP (lanIp or publicIp).
  sshMatchBlockHosts =
    let
      hostNames = builtins.attrNames hosts;
      withUnderscore = name:
        let h = hosts.${name}; in
        if (h ? lanIp || h ? publicIp)
        then [ name "${name}_" ]
        else [ name ];
    in
    builtins.concatLists (map withUnderscore hostNames);

  # ─── SSH CONFIG GENERATOR ─────────────────────────────────────────
  # Generates SSH matchBlocks from the host registry for use in HM ssh module.
  #
  # The convention is:
  #   - Hosts with overlayIp: base matchBlock uses MagicDNS (no hostname),
  #     underscore variant (e.g. "h001_") uses lanIp (preferred) or publicIp
  #     for direct access.
  #   - Hosts WITHOUT overlayIp: both the base matchBlock AND the `_` variant
  #     get hostname set to the direct IP (lanIp preferred, else publicIp).
  #     They're aliases — `juni` and `juni_` both resolve to the lanIp.
  mkSshMatchBlocks =
    let
      mkBlock = name: h:
        let
          # home-manager 26.05 `programs.ssh.settings` uses upstream OpenSSH
          # directive names (User, HostName, SetEnv) instead of the old
          # camelCase matchBlocks option names.
          user = h.user;
          termEnvAttrs = if h ? sshTermEnv then { SetEnv.TERM = h.sshTermEnv; } else {};
          hasOverlay = h ? overlayIp;
          hasPublic = h ? publicIp;
          hasLan = h ? lanIp;

          # Direct IP — lanIp preferred, else publicIp.
          directIp =
            if hasLan then h.lanIp
            else if hasPublic then h.publicIp
            else null;

          # For hosts not on tailnet, put the direct IP on the main block.
          mainHostname =
            if !hasOverlay && directIp != null then { HostName = directIp; }
            else {};

          baseBlock = { User = user; } // termEnvAttrs // mainHostname;

          # The `_` variant exists whenever a direct IP is available.
          underscoreBlock =
            if directIp != null then {
              "${name}_" = { User = user; } // termEnvAttrs // { HostName = directIp; };
            } else {};
        in
        { "${name}" = baseBlock; } // underscoreBlock;
    in
    builtins.foldl' (acc: name: acc // mkBlock name hosts.${name})
      {} (builtins.attrNames hosts);

  # ─── h001 DNS RECORDS ─────────────────────────────────────────────
  # Subdomains served by h001, used for headscale DNS splitting and /etc/hosts
  h001Subdomains = [
    "jellyfin" "media" "books" "notes" "chat" "sso-proxy" "n8n"
    "sec" "sso" "gist" "git" "etebase" "photos"
    "location" "matrix" "element" "docs" "pkm"
  ];

  # ─── HOST BUILDER ─────────────────────────────────────────────────
  #
  # Eliminates per-host boilerplate by handling:
  #   - Home Manager setup (useUserPackages, useGlobalPkgs, backupFileExtension)
  #   - Base HM shared modules (tmux, atuin, direnv, git, etc.) — toggle with includeBaseHmModules
  #   - Base NixOS modules (empty for now) — toggle with includeBaseNixModules
  #   - System config (stateVersion, hostName, nh.flake, allowUnfree)
  #   - User creation with SSH authorized key
  #   - secrets-bao integration (if secretsRole is set)
  #   - specialArgs passing (inputs, constants, fleet)
  #
  mkHost =
    {
      # Required
      inputs,         # The host's flake inputs attrset
      constants,      # The host's _constants.nix

      # Module selection
      nixosModules ? [],              # Extra NixOS modules (host-specific services, hardware, etc.)
      hmModules ? [],                 # Extra HM shared modules beyond base set
      includeBaseHmModules ? true,    # Include the base set of HM modules (tmux, atuin, etc.)
      includeBaseNixModules ? true,   # Include the base set of NixOS modules (currently empty, for future use)

      # User auth — how the primary user authenticates
      # "initialPassword"       → users.users.*.initialPassword = authValue
      # "hashedPassword"        → users.users.*.hashedPassword = authValue
      # "initialHashedPassword" → users.users.*.initialHashedPassword = authValue
      # "cloudUser"             → no password attrs, user already exists (cloud/VPS root)
      #
      # There is deliberately NO weak default password. `authValue` defaults to
      # null; a password-based host that sets a secretsRole MUST pass an explicit
      # authValue (a `mkpasswd`-style hash, or "!"/"*" to disable password login
      # and go keys-only) or the build fails. See the guard below. This removes
      # the old public `password1` default (pentest C2).
      authMethod ? "hashedPassword",
      authValue ? null,
      # Immutable users by default — declarative passwords, no drift. Override
      # to true only where you genuinely need runtime user/password mutation.
      mutableUsers ? false,
      extraGroups ? [ "wheel" "networkmanager" "video" "input" ],

      # Secrets
      secretsRole ? null,  # "machines-hightrust" | "machines-lowtrust" | null (no secrets)

      # Unstable overlay — pass the nixpkgs-unstable input to get pkgs.unstable
      nixpkgsUnstable ? null,
    }:
    let
      lib = inputs.nixpkgs.lib;

      hostName = constants.host.name;
      stateVersion = constants.host.stateVersion;
      primaryUser = constants.host.primaryUser;
      isCloudUser = authMethod == "cloudUser";

      # ── Auth guard (pentest C2) ──
      # Refuse to build a password-authenticated host that didn't declare its
      # own credential. This makes the old silent `password1` default
      # impossible to reintroduce: any secretsRole host using a password
      # authMethod must pass an explicit authValue (a real hash, or "!"/"*" to
      # disable password login and rely on SSH keys).
      _authGuard =
        if (!isCloudUser) && authValue == null then
          throw ("fleet.mkHost: host '${hostName}' uses authMethod=\"${authMethod}\" "
            + "but did not set an explicit `authValue`. There is no default "
            + "password. Set a `mkpasswd`-generated hash, or authValue = \"!\" "
            + "to disable password login (keys-only). See pentest C2.")
        else null;

      fleetData = { inherit global hosts h001Subdomains mkSshMatchBlocks; };

      # ── secrets-bao integration ──
      hasSecretsBao = secretsRole != null && inputs ? secrets-bao;
      autoSecrets =
        if hasSecretsBao then
          inputs.secrets-bao.lib.mkAutoSecrets {
            role = secretsRole;
            inherit primaryUser;
          }
        else {};
      allSecrets =
        if hasSecretsBao then
          autoSecrets // (constants.secrets or {})
        else {};

      secretsBaoModules =
        if hasSecretsBao then [
          inputs.secrets-bao.nixosModules.default
          (
            { lib, ... }:
            lib.mkMerge [
              {
                ringofstorms.secretsBao = {
                  enable = true;
                  openBaoRole = secretsRole;
                  secrets = allSecrets;
                };
              }
              (inputs.secrets-bao.lib.applyChanges allSecrets)
            ]
          )
        ] else [];

      # ── Unstable overlay ──
      unstableOverlay =
        if nixpkgsUnstable != null then [
          ({
            nixpkgs.overlays = [
              (final: prev: {
                unstable = import nixpkgsUnstable {
                  inherit (final) system config;
                };
              })
            ];
          })
        ] else [];

      # ── Home Manager base modules ──
      # These 9 modules are shared by every single host (unless includeBaseHmModules = false).
      baseHmModules =
        if includeBaseHmModules then [
          inputs.common.homeManagerModules.tmux
          inputs.common.homeManagerModules.atuin
          inputs.common.homeManagerModules.direnv
          inputs.common.homeManagerModules.git
          inputs.common.homeManagerModules.postgres_cli_options
          inputs.common.homeManagerModules.ssh
          inputs.common.homeManagerModules.starship
          inputs.common.homeManagerModules.zoxide
          inputs.common.homeManagerModules.zsh
        ] else [];

      # ── NixOS base modules ──
      # Common NixOS modules included on all hosts (unless includeBaseNixModules = false).
      # Currently empty — add modules here as patterns emerge across hosts.
      baseNixModules =
        if includeBaseNixModules then [
        ] else [];

      # ── Low-trust Tailnet DNS policy ──
      # Headscale advertises one DNS configuration to the whole tailnet; ACL
      # tags cannot select a different nameserver.split policy. Low-trust
      # clients therefore keep using their LAN/public resolvers instead of
      # accepting the tailnet-wide split DNS configuration.
      lowTrustTailnetDnsModule =
        lib.optional (secretsRole == "machines-lowtrust") {
          services.tailscale.extraUpFlags = [ "--accept-dns=false" ];
          services.tailscale.extraSetFlags = [ "--accept-dns=false" ];
        };

      # ── User auth config ──
      # `builtins.seq _authGuard` forces the guard to evaluate (throwing for a
      # password host with no authValue) before any auth attrs are produced.
      userAuthAttrs = builtins.seq _authGuard (
        if authMethod == "initialPassword" then { initialPassword = authValue; }
        else if authMethod == "hashedPassword" then { hashedPassword = authValue; }
        else if authMethod == "initialHashedPassword" then { initialHashedPassword = authValue; }
        else {} # cloudUser — no password attrs
      );

      # ── HM user set (explicit to avoid infinite recursion with config.users.users) ──
      hmUsers =
        let base = { "${primaryUser}" = { home.stateVersion = stateVersion; programs.home-manager.enable = true; }; };
        in base;

      # ── Core system module (the boilerplate that used to be copy-pasted) ──
      coreModule =
        { config, pkgs, ... }:
        {
          system.stateVersion = stateVersion;
          networking.hostName = hostName;
          programs.nh.flake = "/home/${primaryUser}/.config/nixos-config/hosts/${hostName}";
          nixpkgs.config.allowUnfree = true;

          users.mutableUsers = mutableUsers;

          users.users."${primaryUser}" =
            (if isCloudUser then {
              shell = pkgs.zsh;
              openssh.authorizedKeys.keys = [ global.sshPubKey ];
            } else {
              isNormalUser = true;
              inherit extraGroups;
              openssh.authorizedKeys.keys = [ global.sshPubKey ];
            }) // userAuthAttrs;

          # Home Manager
          home-manager = {
            useUserPackages = true;
            useGlobalPkgs = true;
            backupFileExtension = "bak";
            users = hmUsers;

            sharedModules = baseHmModules ++ hmModules;

            extraSpecialArgs = {
              inherit inputs;
              fleet = fleetData;
            };
          };
        };

    in
    lib.nixosSystem {
      specialArgs = {
        inherit inputs constants;
        fleet = fleetData;
      };
      modules =
        # Unstable overlay (if present, must come first so pkgs.unstable is available)
        unstableOverlay

        # Home Manager
        ++ [ inputs.home-manager.nixosModules.default ]

        # secrets-bao (if role is set)
        ++ secretsBaoModules

        # Base NixOS modules
        ++ baseNixModules

        # Core system boilerplate
        ++ [ coreModule ]

        # Low-trust hosts must not accept the tailnet-wide Headscale DNS
        # split; their normal LAN/public DNS provides the service records.
        ++ lowTrustTailnetDnsModule

        # Host-specific modules
        ++ nixosModules;
    };
}
