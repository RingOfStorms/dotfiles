{ settings, pkgs, ... }:
{
  # users.users.${settings.user.username}.packages = [ pkgs.ulauncher ];

  # systemd.services.ulauncher = {
  #   unitConfig = {
  #     "Description" = "Linux Application Launcher";
  #     "Documentation" = [ "https://ulauncher.io/" ];
  #   };
  #   wantedBy = [ "graphical-session.target" ];
  #   after = [ "graphical-session.target" ];
  #   serviceConfig = {
  #     User = "${settings.user.username}";
  #     Type = "simple";
  #     Restart = "always";
  #     RestartSec = 1;
  #     # ExecStart = "${pkgs.ulauncher}/bin/ulauncher --hide-window";
  #     ExecStart = pkgs.writeShellScript "ulauncher-env-wrapper.sh" ''
  #       export GDK_BACKEND=x11
  #       exec ${pkgs.ulauncher}/bin/ulauncher --hide-window
  #     '';
  #   };
  # };
  
  # systemd.user.services.ulauncher = {
  #   description = "Start Ulauncher";
  #   script = "${pkgs.ulauncher}/bin/ulauncher --hide-window";
  #   wantedBy = [ "graphical.target" "multi-user.target" ];
  #   after = [ "greetd.service" ];
  # };
}
