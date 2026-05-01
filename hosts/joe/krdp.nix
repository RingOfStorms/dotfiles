# KRDP — KDE Plasma 6 RDP server (joe-only, will be promoted to a shared
# common module once it's been validated end-to-end).
#
# Why a user systemd unit:
#   krdpserver renders the live Plasma session over RDP via the
#   xdg-desktop-portal Remote Desktop interface. That portal only exists
#   inside a logged-in graphical user session — there's no system-mode
#   capture path for Wayland. So we run the server as a user unit that
#   starts when the user's Plasma session comes up.
#
#   Caveat: this means the user has to be logged in for RDP to work.
#   joe is fine — it has SDDM autologin to ${primaryUser} configured in
#   the dePlasma module. If the user logs out we lose RDP until next login.
#
# Why we don't use the upstream `app-org.kde.krdpserver.service` user unit:
#   The upstream unit reads the username/password from KWallet via the
#   KCM. Storing/rotating those programmatically from Nix means scripting
#   the kwallet daemon and the KRDP KCM, which is fragile across Plasma
#   versions. Instead we run a plain user unit that invokes
#   `krdpserver -u <user> -p <pass>` directly with the credential pulled
#   from openbao at activation time. The single-user-per-server limitation
#   is fine for our use case (one machine, one human, plus Guacamole
#   acting as that human).
#
# Connecting:
#   xfreerdp /u:josh /p:<password> -clipboard /v:<joe-ip>:3389
#
{
  config,
  lib,
  pkgs,
  constants,
  ...
}:
let
  c = constants.services.krdp;
  user = constants.host.primaryUser;
  passwordFile = "/var/lib/openbao-secrets/krdp_password";
  certPath = "/var/lib/krdp/krdp.crt";
  certKeyPath = "/var/lib/krdp/krdp.key";

  # Wrapper that reads the password file at startup and execs krdpserver
  # with -u/-p. Doing this in a wrapper (instead of baking the path into
  # ExecStart and letting systemd interpolate) keeps the password off
  # /proc/<pid>/cmdline. It's still visible to anyone who can read this
  # process's memory, but that's strictly better than cmdline leakage.
  startScript = pkgs.writeShellScript "krdpserver-start" ''
    set -euo pipefail

    if [ ! -s "${passwordFile}" ]; then
      echo "krdpserver: password file empty or missing: ${passwordFile}" >&2
      exit 1
    fi

    if [ ! -s "${certPath}" ] || [ ! -s "${certKeyPath}" ]; then
      echo "krdpserver: TLS cert/key missing — generating self-signed pair" >&2
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "${certPath}")"
      ${pkgs.openssl}/bin/openssl req \
        -nodes -new -x509 \
        -keyout "${certKeyPath}" \
        -out    "${certPath}" \
        -days 825 -batch \
        -subj "/CN=krdp-${config.networking.hostName}"
      ${pkgs.coreutils}/bin/chmod 600 "${certKeyPath}"
    fi

    pw="$(${pkgs.coreutils}/bin/cat "${passwordFile}")"

    exec ${pkgs.kdePackages.krdp}/bin/krdpserver \
      -u ${lib.escapeShellArg user} \
      -p "$pw" \
      --port ${toString c.port} \
      --certificate     "${certPath}" \
      --certificate-key "${certKeyPath}"
  '';
in
{
  # KRDP is already pulled in by Plasma 6's optional packages — but be
  # explicit so we own the dependency and don't silently break if upstream
  # drops it from the default set.
  environment.systemPackages = [ pkgs.kdePackages.krdp ];

  # Persistent state directory for the self-signed cert.
  systemd.tmpfiles.rules = [
    "d /var/lib/krdp 0750 ${user} users - -"
  ];

  # Run the server as a user systemd unit — needs the Plasma session.
  systemd.user.services.krdpserver = {
    description = "KDE Remote Desktop Protocol server (KRDP)";
    # Pull in graphical-session.target so we only run inside a real
    # graphical session (i.e. Plasma is up).
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];

    # Ensure the password is available; if not, fail fast and let the
    # secret-changed path unit retry us when openbao renders it.
    unitConfig.ConditionFileNotEmpty = passwordFile;

    serviceConfig = {
      Type = "simple";
      ExecStart = startScript;
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Open RDP only on the tailnet interface — same posture as the
  # rustdesk-server module on o001. Anyone wanting in must be on the
  # tailnet (or be Guacamole running on h001, which also goes via
  # tailscale to reach joe).
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
}
