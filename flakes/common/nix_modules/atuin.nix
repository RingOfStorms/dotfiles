# Atuin shell history sync, system-side glue.
#
# The home-manager `atuin.nix` module enables `programs.atuin` for the
# user. This module installs the system-wide binary and (optionally)
# adds a oneshot systemd service that logs the configured user into
# the Atuin sync server on boot if they're not already logged in.
#
# Wiring:
#
#   ringofstorms.atuin = {
#     enable = true;
#     autologin = {
#       enable = true;
#       user = "josh";
#       group = "users";
#       # File must contain three newline-separated lines:
#       #   <username>\n<password>\n<key>\n
#       # Typically rendered by secrets-bao; see _constants.nix:
#       #   "atuin-key-josh_2026-03-15" = {
#       #     owner = "josh";
#       #     group = "users";
#       #     mode  = "0400";
#       #     hardDepend = [ "atuin-autologin" ];
#       #     template = ''{{- with secret "kv/data/.../atuin-key-josh_..." -}}{{ printf "%s\n%s\n%s" .Data.data.user .Data.data.password .Data.data.value }}{{- end -}}'';
#       #   };
#       secretFile = "/var/lib/openbao-secrets/atuin-key-josh_2026-03-15";
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.atuin;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    types
    ;
in
{
  options.ringofstorms.atuin = {
    enable = mkEnableOption "atuin shell history (system-wide install)";

    package = mkOption {
      type = types.package;
      default = pkgs.atuin;
      description = "The atuin package to use.";
    };

    autologin = {
      enable = mkEnableOption "boot-time atuin login from a secrets file";

      user = mkOption {
        type = types.str;
        description = "User account to log in as (HOME/XDG paths derived from this).";
      };

      group = mkOption {
        type = types.str;
        default = "users";
        description = "Primary group of the user.";
      };

      secretFile = mkOption {
        type = types.str;
        description = ''
          Path to a file containing three newline-separated lines:
          username, password, key. Read by the autologin oneshot.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = [ cfg.package ];
    }

    (mkIf cfg.autologin.enable {
      systemd.services.atuin-autologin = {
        description = "Auto-login to Atuin (if logged out)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.autologin.user;
          Group = cfg.autologin.group;
          Environment = [
            "HOME=/home/${cfg.autologin.user}"
            "XDG_CONFIG_HOME=/home/${cfg.autologin.user}/.config"
            "XDG_DATA_HOME=/home/${cfg.autologin.user}/.local/share"
          ];
          ExecStart = pkgs.writeShellScript "atuin-autologin" ''
            #!/usr/bin/env bash
            set -euo pipefail

            if ! ${pkgs.iputils}/bin/ping -c1 -W2 1.1.1.1 &>/dev/null; then
              echo "No network access, skipping atuin login"
              exit 0
            fi

            secret="${cfg.autologin.secretFile}"
            if [ ! -s "$secret" ]; then
              echo "Missing atuin secret at $secret" >&2
              exit 1
            fi

            # status exits non-zero when logged out.
            out="$(${cfg.package}/bin/atuin status 2>&1)" && exit 0

            if [[ "$out" != *"You are not logged in"* ]]; then
              echo "$out" >&2
              exit 1
            fi

            username="$(${pkgs.gnused}/bin/sed -n '1p' "$secret")"
            password="$(${pkgs.gnused}/bin/sed -n '2p' "$secret")"
            key="$(${pkgs.gnused}/bin/sed -n '3p' "$secret")"

            exec ${cfg.package}/bin/atuin login --username "$username" --password "$password" --key "$key"
          '';
        };
      };
    })
  ]);
}
