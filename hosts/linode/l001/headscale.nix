{ pkgs, ... }:
{

  config = {
    # TODO backup /var/lib/headscale data
    # TODO https://github.com/gurucomputing/headscale-ui ?
    environment.systemPackages = with pkgs; [ headscale ];
    services.headscale = {
      enable = true;
      settings = {
        server_url = "https://nexus.joshuabell.xyz";
        database.type = "sqlite3";
        derp = {
          auto_update_enable = true;
          update_frequency = "5m";
        };
        dns = {
          magic_dns = true;
          base_domain = "net.joshuabell.xyz";
        };
      };
    };
  };
}
