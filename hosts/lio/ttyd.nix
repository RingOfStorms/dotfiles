{
  pkgs,
  ...
}:
{
  systemd.services.ttyd = {
    description = "TTYD - Web Terminal";
    after = [ "network.target" "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "josh";
      Group = "users";
      ExecStart = "${pkgs.ttyd}/bin/ttyd -p 8383 -i 100.64.0.1 -W -c :root -t fontSize=56 -t rendererType=webgl -t disableLeaveAlert=true ${pkgs.zsh}/bin/zsh";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
