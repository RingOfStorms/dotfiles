# gnome-remote-desktop — RDP server that works on Plasma 6 Wayland.
#
# Why this and not KRDP:
#   nixpkgs's kdePackages.krdp is built without the H.264 encoder libs
#   (openh264, x264) that KRdp needs at build time. Without them KRDP
#   negotiates RDPGFX_CAPVERSION_107 then silently fails to encode any
#   frames, leaving the client on a black screen until it times out.
#   gnome-remote-desktop ships the right encoder pipeline out of the
#   box and works on Plasma 6 Wayland (it uses the same xdg-desktop-
#   portal Remote Desktop API as KRDP, but with a working encoder).
#
# Mode used: "user" (live-session). The daemon attaches to the running
# Plasma session and mirrors it to RDP clients. Requires the user to
# be logged in — handled by SDDM autologin on this host.
#
# Connecting:
#   xfreerdp /u:luser /p:'<openbao value>' /v:gp3:3389 /cert:ignore +clipboard
#
{
  config,
  lib,
  pkgs,
  constants,
  ...
}:
let
  c = constants.services.grd;
  user = constants.host.primaryUser;
  passwordFile = "/var/lib/openbao-secrets/krdp_password";
in
{
  # Enable the daemon (sets up systemd user units, dbus, etc.)
  services.gnome.gnome-remote-desktop.enable = true;

  # Make the CLI available system-wide for debugging.
  environment.systemPackages = [ pkgs.gnome-remote-desktop ];

  # Open RDP only on the tailnet interface — same posture as the rest
  # of the fleet. Clients must be on the tailnet (or be Guacamole on
  # h001 talking to gp3 over tailscale).
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];

  # The grd-user-configurator service runs as the desktop user once
  # Plasma comes up, applies the password from openbao, and enables
  # RDP. It re-runs whenever the password file changes (the path unit
  # in secrets-bao triggers a softDepend restart).
  systemd.user.services.grd-configure = {
    description = "Apply gnome-remote-desktop credentials from openbao";

    # Wait for the gnome-remote-desktop user daemon (started by the
    # dbus activation file shipped in the package) and the graphical
    # session to be ready.
    wantedBy = [ "graphical-session.target" ];
    after    = [ "graphical-session.target" "gnome-remote-desktop.service" ];
    partOf   = [ "graphical-session.target" ];

    unitConfig.ConditionFileNotEmpty = passwordFile;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "grd-configure" ''
        set -euo pipefail

        PW="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg passwordFile})"

        # RDP backend config — username, password, port, no TLS prompt.
        # grdctl writes to ~/.config/gnome-remote-desktop/grd-settings
        # and the daemon picks it up via gsettings.
        ${pkgs.gnome-remote-desktop}/bin/grdctl rdp set-credentials ${lib.escapeShellArg user} "$PW"
        ${pkgs.gnome-remote-desktop}/bin/grdctl rdp set-port ${toString c.port}
        ${pkgs.gnome-remote-desktop}/bin/grdctl rdp disable-view-only
        ${pkgs.gnome-remote-desktop}/bin/grdctl rdp enable
      '';
    };
  };
}
