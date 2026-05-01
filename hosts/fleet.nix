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
      overlayIp = "100.64.0.5";
      trust = "high";
    };
    gp3 = {
      user = "luser";
      lanIp = "10.12.14.144";
      trust = "low";
    };
    l001 = {
      user = "root";
      publicIp = "172.236.111.33";
      trust = "none";
      flakePath = "hosts/linode/l001";
    };
    o001 = {
      user = "root";
      overlayIp = "100.64.0.11";
      publicIp = "64.181.210.7";
      trust = "high";
      flakePath = "hosts/oracle/o001";
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
  #     underscore variant (e.g. "h001_") uses lanIp for direct LAN access.
  #   - Hosts with ONLY publicIp (no overlayIp, e.g. l001): base matchBlock
  #     gets hostname set to publicIp, underscore variant also gets publicIp.
  #   - Hosts with lanIp but no overlayIp (e.g. t): base uses MagicDNS,
  #     underscore variant uses lanIp.
  mkSshMatchBlocks =
    let
      mkBlock = name: h:
        let
          user = h.user;
          termEnvAttrs = if h ? sshTermEnv then { setEnv.TERM = h.sshTermEnv; } else {};
          hasOverlay = h ? overlayIp;
          hasPublic = h ? publicIp;
          hasLan = h ? lanIp;

          # For hosts not on tailnet but with a publicIp, set hostname on the main block
          mainHostname =
            if !hasOverlay && hasPublic then { hostname = h.publicIp; }
            else {};

          baseBlock = { inherit user; } // termEnvAttrs // mainHostname;

          # The _ variant uses lanIp (preferred) or publicIp for direct access
          directIp =
            if hasLan then h.lanIp
            else if hasPublic then h.publicIp
            else null;
          underscoreBlock =
            if directIp != null then {
              "${name}_" = { inherit user; } // termEnvAttrs // { hostname = directIp; };
            } else {};
        in
        { "${name}" = baseBlock; } // underscoreBlock;
    in
    builtins.foldl' (acc: name: acc // mkBlock name hosts.${name})
      {} (builtins.attrNames hosts);

  # ─── h001 DNS RECORDS ─────────────────────────────────────────────
  # Subdomains served by h001, used for headscale DNS splitting and /etc/hosts
  h001Subdomains = [
    "jellyfin" "media" "notes" "chat" "sso-proxy" "n8n"
    "sec" "sso" "gist" "git" "blog" "etebase" "photos"
    "location" "matrix" "element" "docs" "guac"
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
      authMethod ? "initialPassword",
      authValue ? "password1",
      mutableUsers ? true,
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

      # ── User auth config ──
      userAuthAttrs =
        if authMethod == "initialPassword" then { initialPassword = authValue; }
        else if authMethod == "hashedPassword" then { hashedPassword = authValue; }
        else if authMethod == "initialHashedPassword" then { initialHashedPassword = authValue; }
        else {}; # cloudUser — no password attrs

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

        # Host-specific modules
        ++ nixosModules;
    };
}
