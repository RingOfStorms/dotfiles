{
  lib,
  config,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "general"
    "reporting"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "Reporting node info and logs to grafana";
      lokiUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://h001.net.joshuabell.xyz:3100/loki/api/v1/push";
        description = "URL of the Loki instance to send logs to";
      };
    };

  config = lib.mkIf cfg.enable {
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
            url = cfg.lokiUrl;
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
