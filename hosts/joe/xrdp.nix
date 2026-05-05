# xrdp — RDP server that spawns a fresh Plasma session per RDP login.
#
# Why xrdp instead of KRDP / GRD:
#   - KRDP needs a custom kpipewire build (with ffmpeg-full / openh264)
#     to actually encode H.264 frames. That rebuild is huge (kpipewire
#     touches a third of the KDE stack) and prohibitive on every
#     nixpkgs bump.
#   - gnome-remote-desktop's user/screen-share mode is GNOME-Mutter-only
#     and silently no-ops on Plasma KWin.
#   - xrdp runs a separate Xorg-on-X11 Plasma session per login. We
#     LOSE live-session mirroring (you won't see what's currently on
#     joe's monitor), but we GAIN a working RDP server with no rebuilds
#     and broad client compatibility.
#
# How it works:
#   1. xrdp listens on TCP 3389 (tailnet only, behind firewall).
#   2. RDP client connects, PAM authenticates the user against the
#      system password (xrdp-sesman PAM stack).
#   3. xrdp-sesman launches `startwm.sh`, which we configure to start
#      a Plasma X11 session.
#   4. Each connection spawns its own Xorg display (:10, :11, ...).
#   5. Disconnect leaves the session running; reconnect picks it back
#      up where you left off.
#
# Caveats:
#   - You don't see joe's physical monitor — that's a separate
#     Plasma-on-Wayland session owned by the autologin user.
#   - If you connect as the same user that's autologged-in physically
#     (luser/josh), Plasma may complain about a duplicate session.
#     Easiest workaround: log in over RDP as a different user.
#     (Future: dedicated rdp user with its own home, or just live with
#     the duplicate-session warning.)
#   - Audio is PulseAudio-only via pulseaudio-module-xrdp; we use
#     PipeWire's PulseAudio shim so this *might* work — try it.
#   - Wayland-only apps (rare in Plasma 6) won't work; everything goes
#     through XWayland or runs natively on Xorg.
#
# Connecting:
#   xfreerdp /u:josh /p:'<system password>' /v:joe:3389 /cert:ignore +clipboard /size:1920x1080
{
  config,
  lib,
  pkgs,
  constants,
  ...
}:
let
  c = constants.services.xrdp;
in
{
  services.xrdp = {
    enable = true;
    port = c.port;

    # Don't auto-open the firewall — we only want xrdp reachable on the
    # tailnet, not on LAN/public. We open the port ourselves below.
    openFirewall = false;

    # Move the TLS cert/key out of /etc/xrdp (which the upstream module
    # makes a nix-store symlink) and into /var/lib/xrdp so we can persist
    # them via impermanence and survive RDP-client cert-trust across
    # reboots.
    sslCert = "/var/lib/xrdp/cert.pem";
    sslKey  = "/var/lib/xrdp/key.pem";

    # Launch a full Plasma 6 X11 session for each RDP login.
    # `startplasma-x11` is provided by kdePackages.plasma-workspace,
    # which is already in the system closure via the dePlasma module.
    defaultWindowManager = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-x11";

    # Audio over RDP. xrdp uses PulseAudio modules, but joe runs
    # PipeWire with the pulse shim (services.pipewire.pulse.enable in
    # de_plasma). This may or may not work — try it; if not, we can
    # disable.
    audio.enable = true;
  };

  # Persistent state directory for the xrdp TLS cert+key (persisted via
  # impermanence so RDP clients don't have to re-trust on every boot).
  systemd.tmpfiles.rules = [
    "d /var/lib/xrdp 0750 xrdp xrdp - -"
  ];

  # xrdp port restricted to the tailnet, mirroring the rest of the
  # fleet's RDP/Guacamole posture.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
}
