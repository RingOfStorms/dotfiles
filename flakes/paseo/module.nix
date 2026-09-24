{ self }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.paseoBareMetal;
  inherit (lib) mkIf mkOption types;
  launcher = self.lib.mkProviderLauncher { inherit pkgs; };
  hostnames = [ "localhost" ] ++ lib.optional (cfg.proxy.domain != null) cfg.proxy.domain;
  opencodeConfig = {
    daemon = {
      listen = "127.0.0.1:${toString cfg.port}";
      hostnames = hostnames ++ lib.optional (cfg.proxy.domain != null) "${cfg.proxy.domain}:443";
      relay.enabled = false;
    }
    // lib.optionalAttrs (cfg.proxy.domain != null) {
      trustedProxies = [ "loopback" ];
      cors.allowedOrigins = [ "https://${cfg.proxy.domain}" ];
    };
    app.baseUrl =
      if cfg.proxy.domain == null then "http://127.0.0.1:${toString cfg.port}"
      else "https://${cfg.proxy.domain}";
    features.webUi.enabled = true;
    worktrees.root = cfg.worktreesDir;
    agents.providers = {
      claude.enabled = false;
      codex.enabled = false;
      copilot.enabled = false;
      opencode.enabled = true;
      pi.enabled = false;
      omp.enabled = cfg.ompPackage != null;
    };
    pluginsEnabled = false;
  };
in
{
  imports = [ self.nixosModules.upstream ];

  options.services.paseoBareMetal = {
    enable = lib.mkEnableOption "bare-metal Paseo daemon with mandatory Nono provider sandbox";
    user = mkOption { type = types.str; default = "josh"; };
    uid = mkOption { type = types.ints.positive; default = 1000; description = "Numeric UID used for XDG runtime and SSH agent paths."; };
    group = mkOption { type = types.str; default = "users"; };
    home = mkOption { type = types.str; default = "/home/josh"; };
    dataDir = mkOption { type = types.str; default = "/home/josh/.paseo"; };
    projects = mkOption {
      type = types.listOf types.path;
      default = [ /home/josh/projects /home/josh/other ];
      description = "Existing host directories available for normal Paseo workspace selection.";
    };
    catalogWorkdir = mkOption {
      type = types.str;
      default = "/home/josh/projects";
      description = "Absolute existing writable project directory used for global provider catalog discovery.";
    };
    worktreesDir = mkOption { type = types.str; default = "/home/josh/.paseo/worktrees"; };
    port = mkOption { type = types.port; default = 6767; };
    proxy.domain = mkOption { type = types.nullOr types.str; default = null; };
    environmentFile = mkOption {
      type = types.str;
      default = "/var/lib/secrets_manager_hydrated/paseo_agent_env_2026-09-21";
      description = "Secret EnvironmentFile containing PASEO_PASSWORD_BCRYPT.";
    };
    opencodePackage = mkOption { type = types.package; default = self.packages.${pkgs.stdenv.hostPlatform.system}.opencode; description = "OpenCode 1.x runtime used only inside the mandatory provider launcher."; };
    paseoPackage = mkOption { type = types.package; default = self.packages.${pkgs.stdenv.hostPlatform.system}.paseo; };
    ompPackage = mkOption { type = types.nullOr types.package; default = null; };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.user != "paseo"; message = "services.paseoBareMetal must run as the existing host user."; }
      { assertion = lib.hasPrefix "/" cfg.catalogWorkdir; message = "services.paseoBareMetal.catalogWorkdir must be an absolute path."; }
      { assertion = builtins.any (project: cfg.catalogWorkdir == toString project) cfg.projects; message = "services.paseoBareMetal.catalogWorkdir must be one of services.paseoBareMetal.projects."; }
    ];

    users.manageLingering = true;
    users.users.${cfg.user}.linger = true;
    programs.ssh.startAgent = true;

    services.paseo = {
      enable = true;
      package = cfg.paseoPackage;
      user = cfg.user;
      group = cfg.group;
      dataDir = cfg.dataDir;
      port = cfg.port;
      listenAddress = "127.0.0.1";
      openFirewall = false;
      hostnames = hostnames ++ lib.optional (cfg.proxy.domain != null) "${cfg.proxy.domain}:443";
      relay.enable = false;
      inheritUserEnvironment = false;
      settings = opencodeConfig;
      environment = {
        HOME = cfg.home;
        USER = cfg.user;
        LOGNAME = cfg.user;
        XDG_CONFIG_HOME = "${cfg.home}/.config";
        XDG_DATA_HOME = "${cfg.home}/.local/share";
        XDG_STATE_HOME = "${cfg.home}/.local/state";
        XDG_CACHE_HOME = "${cfg.home}/.cache";
        OPENCODE_CONFIG = "${cfg.home}/.config/opencode/paseo-1.x.json";
        PASEO_PROVIDER_LAUNCHER = lib.getExe launcher;
        PASEO_PROVIDER_SANDBOX_REQUIRED = "1";
        PASEO_OPENCODE_RUNTIME = lib.getExe cfg.opencodePackage;
        PASEO_OMP_RUNTIME = if cfg.ompPackage != null then lib.getExe cfg.ompPackage else "";
        PASEO_PROVIDER_DEFAULT_CWD = if cfg.catalogWorkdir != null then toString cfg.catalogWorkdir else "";
        OPENCODE_DISABLE_PROJECT_CONFIG = "1";
        XDG_RUNTIME_DIR = "/run/user/${toString cfg.uid}";
        SSH_AUTH_SOCK = "/run/user/${toString cfg.uid}/ssh-agent";
      };
    };

    systemd.services.paseo = {
      after = [ "sec-secrets-ready.service" "user@${toString config.users.users.${cfg.user}.uid}.service" ];
      wants = [ "sec-secrets-ready.service" ];
      path = [ pkgs.coreutils pkgs.jq pkgs.git pkgs.openssh pkgs.procps cfg.paseoPackage cfg.opencodePackage ] ++ lib.optional (cfg.ompPackage != null) cfg.ompPackage;
      serviceConfig = {
        EnvironmentFile = cfg.environmentFile;
        UMask = "0077";
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.dataDir cfg.home "/tmp" ] ++ cfg.projects ++ [ cfg.worktreesDir ];
      };
      preStart = lib.mkAfter ''
        if [ ! -d "${cfg.catalogWorkdir}" ]; then
          echo "PASEO_PROVIDER_DEFAULT_CWD does not exist: ${cfg.catalogWorkdir}" >&2
          exit 1
        fi
        if [ ! -w "${cfg.catalogWorkdir}" ]; then
          echo "PASEO_PROVIDER_DEFAULT_CWD is not writable by ${cfg.user}: ${cfg.catalogWorkdir}" >&2
          exit 1
        fi
        if [ -z "''${PASEO_PASSWORD_BCRYPT:-}" ]; then
          echo "PASEO_PASSWORD_BCRYPT is required in ${cfg.environmentFile}" >&2
          exit 1
        fi
        if ! printf '%s' "$PASEO_PASSWORD_BCRYPT" | ${lib.getExe pkgs.gnugrep} -Eq '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'; then
          echo "PASEO_PASSWORD_BCRYPT must be a bcrypt hash" >&2
          exit 1
        fi
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT
        ${lib.getExe pkgs.jq} --arg password "$PASEO_PASSWORD_BCRYPT" \
          '.daemon.auth.password = $password' ${cfg.dataDir}/config.json > "$tmp"
        install -m 0600 -o ${cfg.user} -g ${cfg.group} "$tmp" ${cfg.dataDir}/config.json
      '';
    };

  };
}
