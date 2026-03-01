{ pkgs, constants, ... }:
let
  hs = constants.services.headscale;
  h001Dns = import ../../../flakes/common/nix_modules/tailnet/h001_dns.nix;
in
{
  config = {
    # TODO backup /var/lib/headscale data
    # TODO https://github.com/gurucomputing/headscale-ui ?
    environment.systemPackages = with pkgs; [ headscale ];
    services.headscale = {
      enable = true;
      settings = {
        server_url = "https://${hs.domain}";
        database.type = "sqlite3";
        derp = {
          auto_update_enable = true;
          update_frequency = "5m";
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
