# RustDesk remote desktop client
#
# Installs rustdesk-flutter, writes RustDesk.toml (server config), creates a
# systemd service for unattended access, and optionally sets a permanent
# password + client ID via an activation script.
#
# The server public key and permanent password should come from secrets-bao.
# Add entries to the host's _constants.nix secrets block:
#
#   "rustdesk_server_key" = {
#     kvPath = "kv/data/machines/<trust>/rustdesk_server_key";
#     softDepend = [ "rustdesk" ];
#   };
#   "rustdesk_password" = {
#     kvPath = "kv/data/machines/by-host/<hostname>/rustdesk_password";
#     softDepend = [ "rustdesk" ];
#   };
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.rustdesk;
  inherit (lib) mkOption mkIf mkMerge types;
in
{
  options.ringofstorms.rustdesk = {
    enable = lib.mkEnableOption "RustDesk remote desktop client";

    package = mkOption {
      type = types.package;
      default = pkgs.rustdesk-flutter;
      description = "The RustDesk package to use.";
    };

    server = mkOption {
      type = types.str;
      description = "Hostname or IP of the RustDesk rendezvous server (hbbs).";
    };

    serverKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a file containing the server's ed25519 public key. Typically a secrets-bao rendered secret.";
    };

    id = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "RustDesk client ID for this machine. Defaults to the hostname.";
    };

    passwordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a file containing the permanent password (plaintext). Typically a secrets-bao rendered secret. Applied via `rustdesk --password`.";
    };

    user = mkOption {
      type = types.str;
      description = "The user account under which RustDesk config files are managed.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = [ cfg.package ];

      # Ensure uinput is available for virtual input devices
      boot.kernelModules = [ "uinput" ];
      services.udev.extraRules = ''
        KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input"
      '';

      # RustDesk background service for unattended access
      systemd.services.rustdesk = {
        description = "RustDesk Service (unattended access)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.package}/bin/rustdesk --service";
          Restart = "always";
          RestartSec = 5;
        };
      };

      # Write RustDesk.toml (server config) — this is deterministic and can
      # be regenerated on every activation.  The server key is read from a
      # file at activation time so it can come from secrets-bao.
      system.activationScripts.rustdesk-config = {
        deps = [ "users" "groups" ];
        text =
          let
            configDir = "/home/${cfg.user}/.config/rustdesk";
            tomlPath = "${configDir}/RustDesk.toml";
            toml2Path = "${configDir}/RustDesk2.toml";
          in
          ''
            # ── RustDesk.toml (server config) ──────────────────────────
            mkdir -p "${configDir}"

            server_key=""
            ${lib.optionalString (cfg.serverKeyFile != null) ''
              if [ -s "${cfg.serverKeyFile}" ]; then
                server_key="$(cat "${cfg.serverKeyFile}" | tr -d '[:space:]')"
              fi
            ''}

            cat > "${tomlPath}" <<TOML
            rendezvous_server = '${cfg.server}:21116'
            nat_type = 1
            serial = 0

            [options]
            custom-rendezvous-server = '${cfg.server}'
            relay-server = ''
            key = '$server_key'
            verification-method = 'use-permanent-password'
            approve-mode = 'password'
            enable-lan-discovery = 'N'
            TOML

            chown ${cfg.user}:users "${tomlPath}"
            chmod 600 "${tomlPath}"

            # ── RustDesk2.toml (client identity) ───────────────────────
            # Only write if the file doesn't exist yet — preserves the
            # auto-generated keypair from first run.
            if [ ! -f "${toml2Path}" ]; then
              cat > "${toml2Path}" <<TOML
            id = '${cfg.id}'
            TOML
              chown ${cfg.user}:users "${toml2Path}"
              chmod 600 "${toml2Path}"
            fi

            # ── Permanent password ─────────────────────────────────────
            ${lib.optionalString (cfg.passwordFile != null) ''
              if [ -s "${cfg.passwordFile}" ]; then
                ${cfg.package}/bin/rustdesk --password "$(cat "${cfg.passwordFile}")" 2>/dev/null || true
              fi
            ''}

            chown -R ${cfg.user}:users "${configDir}"
          '';
      };
    }
  ]);
}
