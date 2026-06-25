# Headscale coordination server — migrated off l001 (Linode) onto o002.
#
# CO-HOST NOTE: o002 also runs tailscaled (it's tailnet node 100.64.0.5).
# Running the headscale coordination server on a machine that is itself a
# tailnet client is officially unsupported. It works here because of the
# mitigations applied in configuration.nix / the tailnet override:
#   - tailscaled uses the PUBLIC server_url (https://headscale.joshuabell.xyz),
#     never the overlay IP, so it doesn't depend on its own tailnet being up.
#   - --accept-dns=false so o002's system DNS does NOT route through its own
#     MagicDNS (which headscale serves) — otherwise a headscale restart would
#     take out o002's DNS and break ACME / everything.
#   - systemd ordering so headscale starts before tailscaled-autoconnect.
{ pkgs, constants, ... }:
let
  hs = constants.services.headscale;
  h001Dns = import ../../../flakes/common/nix_modules/tailnet/h001_dns.nix;

  # Headscale ACL policy (ported verbatim from l001).
  # Deny-by-default: only explicitly listed rules allow traffic.
  # Headscale requires the "@" suffix on user references in ACL policies.
  user = "josh@";

  aclPolicy = {
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

  aclPolicyFile = pkgs.writeText "headscale-acl-policy.json" (builtins.toJSON aclPolicy);
in
{
  environment.systemPackages = with pkgs; [ headscale ];

  # STUN port for embedded DERP server (NAT traversal).
  # NOTE: Oracle's cloud security-list must ALSO open UDP 3478 — the OS
  # firewall rule below is necessary but not sufficient. See readme.md.
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
        # Self-hosted embedded DERP only.
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
}
