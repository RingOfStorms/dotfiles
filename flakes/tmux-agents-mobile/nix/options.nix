# Options shared by the platform modules (NixOS, nix-darwin). The service
# plumbing - a systemd user unit or a launchd agent - lives in those modules, so
# the settings stay identical everywhere.
{ lib, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.services.tmux-agents-mobile = {
    enable = mkEnableOption "the tmux-agents-mobile web UI";

    package = mkOption {
      type = types.package;
      description = "tmux-agents-mobile package to run.";
    };

    user = mkOption {
      type = types.str;
      description = ''
        The account whose tmux server this serves (and therefore the user the
        service runs as). It must be the same user that runs tmux.
      '';
    };

    listen = mkOption {
      type = types.str;
      default = "127.0.0.1:8099";
      description = ''
        Address the UI binds to. Keep it on loopback when there is no
        authentication: the host's proxy terminates TLS and forwards here.
      '';
    };

    healthListen = mkOption {
      type = types.str;
      default = "127.0.0.1:8098";
      description = "Loopback-only /healthz listener; empty string disables it.";
    };

    roots = mkOption {
      type = types.listOf types.str;
      default = [ "~" ];
      description = ''
        Directories a new session may be created in ("~" is the service user's
        home). This is the trust boundary for the web form.
      '';
    };

    sessionKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        File holding the HMAC key for session cookies. Without it a random key
        is generated per boot, so phone sessions are lost on restart (re-login
        is one tap).
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables for the service.";
    };

    zitadel = {
      issuer = mkOption {
        type = types.str;
        default = "";
        example = "https://sso.joshuabell.xyz";
        description = ''
          Zitadel OIDC issuer. With `clientId` empty the app runs **without
          authentication** - acceptable only on a loopback listener.
        '';
      };
      clientId = mkOption {
        type = types.str;
        default = "";
        description = ''
          Client ID of a Zitadel PKCE application whose redirect URI is
          http(s)://<host>/auth/callback. Empty disables authentication.
        '';
      };
      projectId = mkOption {
        type = types.str;
        default = "";
        description = ''
          Zitadel project ID, used for the `aud` scope and the roles claim.
          Empty falls back to the client ID as the audience.
        '';
      };
      claim = mkOption {
        type = types.str;
        default = "flatRolesClaim";
        description = "Zitadel claim holding flat role names.";
      };
      redirectUri = mkOption {
        type = types.str;
        default = "";
        description = "OIDC redirect URI; empty derives it from the request Host.";
      };
      role = mkOption {
        type = types.str;
        default = "";
        description = "Required role from the roles claim; empty allows any project member.";
      };
    };
  };
}
