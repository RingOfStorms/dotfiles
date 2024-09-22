{ pkgs, ... }:
{
  # environment.systemPackages = with pkgs; [
  # ];

  # TODO make a derivation for stormd binary and get it properlly in the store. This is super janky and the binary just has to exist there right now.

  # networking.firewall.allowedUDPPorts = [ 4242 ];

  systemd.services."stormd" = {
    description = "Stormd service";
    wants = [ "basic.target" ];
    after = [
      "basic.target"
      "network.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "notify";
      Restart = "always";
      RestartSec = 1;
      ExecStart = "/etc/stormd/stormd daemon";
    };
    unitConfig = {
      StartLimitIntervalSec = 5;
      StartLimitBurst = 3;
    };
  };
}
