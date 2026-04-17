# ttyd web terminal, exposed on:
#   - LAN     : http://10.12.14.118:8080
#   - Tailnet : http://100.64.0.1:8080
#
# Auth: username "root", any password (matches the -c :root flag).
# Spawns a zsh login shell as the josh user. Two services are needed
# because ttyd's -i flag only accepts a single interface/IP.
{ pkgs, lib, constants, ... }:
let
  lanIp     = "10.12.14.118";
  tailnetIp = "100.64.0.1";
  port      = constants.services.ttyd.port;

  mkTtyd = { name, bindIp, extraAfter ? [ ] }: {
    description = "ttyd web terminal (${name}, ${bindIp}:${toString port})";
    wants    = [ "network-online.target" ];
    after    = [ "network-online.target" ] ++ extraAfter;
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User  = "josh";
      Group = "users";
      ExecStart = "${lib.getExe pkgs.ttyd} -p ${toString port} -i ${bindIp} -W -c :root ${pkgs.zsh}/bin/zsh -l";
      Restart = "always";
      RestartSec = 5;
    };
  };
in
{
  options = { };
  config = {
    systemd.services.ttyd-lan = mkTtyd {
      name   = "lan";
      bindIp = lanIp;
    };

    systemd.services.ttyd-tailnet = mkTtyd {
      name       = "tailnet";
      bindIp     = tailnetIp;
      extraAfter = [ "tailscaled.service" ];
    };

    # Open port 8080 on LAN and tailscale0 only (not on every interface).
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];
    networking.firewall.allowedTCPPorts = [ port ];
  };
}
