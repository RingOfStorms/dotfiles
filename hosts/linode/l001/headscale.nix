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
          extra_records =
            let
              h001ARecord = name: {
                type = "A";
                name = "${name}.joshuabell.xyz";
                value = "100.64.0.13";
              };
              
            in
            [
              # {
              #   type = "A";
              #   name = "jellyfin.joshuabell.xyz";
              #   value = "100.64.0.13";
              # }
              h001ARecord "jellyfin"
              h001ARecord "media"
              h001ARecord "notes"
              h001ARecord "chat"
              h001ARecord "sso-proxy"
              h001ARecord "n8n"
              h001ARecord "sso"
              h001ARecord "gist"
              h001ARecord "git"
            ];
        };
      };
    };
  };
}
