# `services.tmux-agents-mobile.tailnet`: the UI on its own tsnet node, shared
# by every platform module. Off by default.
{ lib }:
let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options = {
    enable = mkEnableOption ''
      serving the UI from its own tailnet node (tsnet, userspace: no
      tailscaled needed). Reaching the node is the authentication - the
      control server's ACLs decide which devices can - so these pages have no
      login even when Zitadel is configured for `listen`
    '';

    hostname = mkOption {
      type = types.str;
      example = "tmux-lio";
      description = "Node name; MagicDNS serves it as <hostname>.<base domain>.";
    };

    controlUrl = mkOption {
      type = types.str;
      default = "";
      example = "https://headscale.example.com";
      description = "Coordination server (Headscale). Empty uses Tailscale's.";
    };

    authKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/tmux-agents-mobile-authkey";
      description = ''
        File with a pre-auth key, readable by the service user. Only used for
        the node's first login; afterwards the state directory carries the
        node's identity. A tagged key (e.g. `tag:lowtrust`) lets the ACLs make
        the node reachable without letting it reach anything. Without a key
        the service logs a login URL.
      '';
    };

    stateDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Node state (keys). Null uses <user config dir>/tmux-agents-mobile/tsnet.
        Keep it: losing it registers a new node with new IPs.
      '';
    };

    listen = mkOption {
      type = types.str;
      default = ":80";
      description = "Listen address on the tailnet node (plain HTTP; WireGuard encrypts the path).";
    };
  };

  environment =
    cfg:
    lib.optionalAttrs cfg.enable (
      {
        TAM_TSNET_HOSTNAME = cfg.hostname;
        TAM_TSNET_CONTROL_URL = cfg.controlUrl;
        TAM_TSNET_LISTEN = cfg.listen;
      }
      // lib.optionalAttrs (cfg.authKeyFile != null) { TAM_TSNET_AUTHKEY_FILE = cfg.authKeyFile; }
      // lib.optionalAttrs (cfg.stateDir != null) { TAM_TSNET_DIR = cfg.stateDir; }
    );
}
