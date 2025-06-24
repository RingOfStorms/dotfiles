{
  config,
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
            {
              targets = [ "100.64.0.13:9100" ];
              labels.instance = config.networking.hostName; # h001
            }
            # {
            #   targets = [ "http://lio.net.joshuabell.xyz:9100" ];
            #   labels.instance = "lio";
            # }
          ];
        }
      ];
    };

    services.grafana = {
      enable = true;
      dataDir = "/var/lib/grafana";
      settings = {
        server = {
          http_port = 3001;
          http_addr = "127.0.0.1";
          serve_from_sub_path = true;
          domain = "h001.net.joshuabell.xyz";
          root_url = "http://h001.net.joshuabell.xyz/grafana/";
          enforce_domain = true;
          enable_gzip = true;
        };
      };
      provision = {
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            url = "http://localhost:9090";
            access = "proxy";
            isDefault = true; # Set as default, if you want
          }
          {
            name = "Loki";
            type = "loki";
            url = "http://localhost:3100";
            access = "proxy";
            isDefault = false;
          }
        ];
      };
    };

    # Loki for log aggregation
    systemd.tmpfiles.rules = [
      "d /var/lib/loki 0755 loki loki -"
      "d /var/lib/loki/chunks 0755 loki loki -"
      "d /var/lib/loki/rules 0755 loki loki -"
      "d /var/lib/loki/compactor 0755 loki loki -"
    ];
    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;

        server = {
          http_listen_port = 3100;
        };

        common = {
          path_prefix = "/var/lib/loki";
          storage = {
            filesystem = {
              chunks_directory = "/var/lib/loki/chunks";
              rules_directory = "/var/lib/loki/rules";
            };
          };
          replication_factor = 1;
          ring = {
            kvstore = {
              store = "inmemory";
            };
          };
        };

        schema_config = {
          configs = [
            {
              from = "2023-01-01";
              store = "boltdb-shipper";
              object_store = "filesystem";
              schema = "v12"; # Updated schema version
              index = {
                prefix = "index_";
                period = "24h"; # Set to 24h period as recommended
              };
            }
          ];
        };

        limits_config = {
          allow_structured_metadata = false; # Disable structured metadata until we upgrade to v13
        };

        ruler = {
          storage = {
            type = "local";
            local = {
              directory = "/var/lib/loki/rules";
            };
          };
          rule_path = "/var/lib/loki/rules";
          ring = {
            kvstore = {
              store = "inmemory";
            };
          };
        };

        compactor = {
          working_directory = "/var/lib/loki/compactor"; # Set working directory
          retention_enabled = true;
          compaction_interval = "5m";
          delete_request_store = "filesystem"; # Add this line for retention configuration
          delete_request_cancel_period = "24h";
        };

        analytics = {
          reporting_enabled = false;
        };
      };
    };
  };
}
