# Dynamic DNS: the `dynamic = "wan-ipv4"` records of dns-records.nix
# publicSpec (home.joshuabell.xyz, the via = router anchor) follow h005's WAN
# IPv4. `fleet-edge ddns` resolves the address over IPv4 echo services and
# creates/updates only those records, under the same bunny lock as
# dns-plan --apply; an unchanged address makes no write. dns-plan reports
# the records as `dynamic` and never writes them.
{
  config,
  constants,
  lib,
  ...
}:
let
  c = constants.services.ddns;
  tokenFile = c.tokenPath;
  edge = config.services.fleet-edge;
in
lib.mkIf (tokenFile != null) {
  systemd.services.ddns-update = {
    description = "Dynamic public DNS records (publicSpec wan-ipv4) via fleet-edge";
    wants = [
      "network-online.target"
      "sec-secrets-ready.service"
    ];
    after = [
      "network-online.target"
      "sec-secrets-ready.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe edge.package} ddns --spec ${edge.overrides.specFile} --key-file ${tokenFile}";
      User = "root";
    };
  };

  systemd.timers.ddns-update = {
    description = "Run DDNS update every ${toString c.interval} minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitInactiveSec = "${toString c.interval}min";
      Persistent = true;
    };
  };
}
