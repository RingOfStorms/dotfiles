{ pkgs, constants, ... }:
let
  hs = constants.services.headscale;
  h001Dns = import ../../../flakes/common/nix_modules/tailnet/h001_dns.nix;

  # Headscale ACL policy
  # Deny-by-default: only explicitly listed rules allow traffic.
  # Currently all nodes are under user "josh" with no tags, so this
  # preserves the existing full-mesh behavior while enabling the policy
  # engine for future low-trust node restrictions.
  # Headscale requires the "@" suffix on user references in ACL policies.
  user = "josh@";

  aclPolicy = {
    # Tag ownership: which users can assign these tags to nodes
    tagOwners = {
      "tag:lowtrust" = [ user ];
    };

    acls = [
      # Full mesh between all josh-owned (untagged) nodes
      {
        action = "accept";
        src = [ user ];
        dst = [ "${user}:*" ];
      }
      # Trusted nodes can reach low-trust nodes
      {
        action = "accept";
        src = [ user ];
        dst = [ "tag:lowtrust:*" ];
      }
      # No rule for tag:lowtrust -> anywhere = denied
    ];
  };

  aclPolicyFile = pkgs.writeText "headscale-acl-policy.json"
    (builtins.toJSON aclPolicy);
in
{
  config = {
    # TODO backup /var/lib/headscale data
    # TODO https://github.com/gurucomputing/headscale-ui ?
    environment.systemPackages = with pkgs; [ headscale ];
    # STUN port for embedded DERP server (NAT traversal)
    networking.firewall.allowedUDPPorts = [ 3478 ];

    services.headscale = {
      enable = true;
      settings = {
        server_url = "https://${hs.domain}";
        database.type = "sqlite3";
        policy.path = "${aclPolicyFile}";
        derp = {
          server = {
            enabled = true;
            region_id = 999;
            region_code = "headscale";
            region_name = "Headscale Embedded DERP";
            stun_listen_addr = "0.0.0.0:3478";
            verify_clients = true;
            automatically_add_embedded_derp_region = true;
          };
          # Self-hosted DERP only. See headscale_derp.md for rationale and
          # alternative approaches we considered.
          urls = [ ];
          auto_update_enable = false;
        };
        dns = {
          magic_dns = true;
          base_domain = hs.baseDomain;
          override_local_dns = false;
          extra_records = map (name: {
            type = "A";
            name = "${name}.${h001Dns.baseDomain}";
            value = h001Dns.ip;
          }) h001Dns.subdomains;
        };
      };
    };
  };
}
