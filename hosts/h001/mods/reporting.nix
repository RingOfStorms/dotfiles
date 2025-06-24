{
  config,
  ...
}:
{
  config = {
    services.prometheus.exporters.node = {
      enable = true;
      port = 9100;
    };
    # Create necessary directories with appropriate permissions
    systemd.tmpfiles.rules = [
      "d /tmp/positions 1777 - - -" # World-writable directory for positions file
      "f /tmp/positions.yaml 0666 - - -" # World-writable positions file
    ];
    users.groups.systemd-journal.members = [ "promtail" ];
    services.promtail = {
      enable = true;
      extraFlags = [
        "-config.expand-env=true"
      ];
      configuration = {
        server = {
          http_listen_port = 9080;
          grpc_listen_port = 0;
        };
        positions = {
          filename = "/tmp/positions.yaml"; # Changed from /var/lib/promtail/positions.yaml
        };
        clients = [
          {
            url = "http://100.64.0.13:3100/loki/api/v1/push"; # Points to your Loki instance
          }
        ];
        scrape_configs = [
          {
            job_name = "journal";
            journal = {
              json = false;
              max_age = "12h";
              path = "/var/log/journal";
              labels = {
                job = "systemd-journal";
                host = config.networking.hostName;
              };
            };
            relabel_configs = [
              {
                source_labels = [ "__journal__systemd_unit" ];
                target_label = "unit";
              }
            ];
          }
        ];
      };
    };
  };
}
