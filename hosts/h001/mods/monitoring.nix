{
  ...
}:
{
  config = {
    services.prometheus = {
      enable = true;
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            { targets = [ "localhost:9100" ]; }
          ];
        }
      ];
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_port = 3001;
          serve_from_sub_path = true;
          domain = "h001.net.joshuabell.xyz";
          root_url = "http://h001.net.joshuabell.xyz/grafana/";
          enforce_domain = true;
          enable_gzip = true;
        };
      };
    };
  };
}
