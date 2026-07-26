{
  constants,
  ...
}:
let
  c = constants.services.tdarr;
  movieDir = "${constants.services.nixarr.mediaDir}/library/movies";
in
{
  # Tdarr is used only for full media health checks. Library setup and scan
  # scheduling remain stateful in the web UI at
  # http://h001.net.joshuabell.xyz:${toString c.webUIPort}.
  services.tdarr = {
    enable = true;
    group = "media";

    server = {
      inherit (c) serverPort webUIPort;
      serverIP = "0.0.0.0";
      serverBindIP = true;
      # The node is local, so only the web UI needs to cross the firewall.
      openFirewall = false;
    };

    nodes.local = {
      type = "mapped";
      workers = {
        transcodeGPU = 0;
        transcodeCPU = 0;
        healthcheckGPU = 0;
        healthcheckCPU = 1;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ c.webUIPort ];

  systemd.services.tdarr-node-local = {
    after = [ "autofs.service" ];
    wants = [ "autofs.service" ];

    # Keep the first deployment report-only even if workers are changed in the
    # UI. The upstream NixOS unit is also protected by ProtectSystem=strict.
    serviceConfig.ReadOnlyPaths = [ "-${movieDir}" ];
  };
}
