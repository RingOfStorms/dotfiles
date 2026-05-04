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

  # GRD needs a TLS cert/key. We generate a self-signed pair into the
  # user's data dir on first run if missing.
  certPath    = "/home/${user}/.local/share/gnome-remote-desktop/grd.crt";
  certKeyPath = "/home/${user}/.local/share/gnome-remote-desktop/grd.key";
in
{
  # Enable the daemon (sets up systemd user units, dbus, etc.)
  services.gnome.gnome-remote-desktop.enable = true;

  # GRD stores credentials in libsecret (org.freedesktop.secrets). On
  # Plasma 6 the KWallet shim that provides this is not auto-started,
  # so grdctl set-credentials fails with "name not activatable".
  # gnome-keyring coexists fine with KWallet and reliably provides the
  # secret service for libsecret consumers. PAM unlocks it on login
  # via the gnome-keyring PAM module.
  services.gnome.gnome-keyring.enable = true;

  # Make sure the keyring is unlocked when the user logs in via SDDM
  # (the gnome-keyring module only enables this for the `login` PAM
  # service by default; SDDM has its own PAM stack).
  security.pam.services.sddm.enableGnomeKeyring = true;
  security.pam.services.sddm-autologin.enableGnomeKeyring = true;
  security.pam.services.passwd.enableGnomeKeyring = true;

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
        # NOTE: deliberately NOT using `set -e` — every grdctl call
        # spits "RDP server certificate is invalid" + exits nonzero on
        # startup whenever the *previous* settings don't have a valid
        # cert path yet, even when the subcommand itself succeeds in
        # writing the new setting. We treat each call as best-effort
        # and verify the end state with `grdctl status` at the end.
        set -uo pipefail

        # ── 1. Ensure TLS cert/key exist ─────────────────────────────
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg certPath})"
        if [ ! -s ${lib.escapeShellArg certPath} ] || [ ! -s ${lib.escapeShellArg certKeyPath} ]; then
          echo "grd-configure: generating self-signed TLS pair" >&2
          ${pkgs.openssl}/bin/openssl req \
            -nodes -new -x509 \
            -keyout ${lib.escapeShellArg certKeyPath} \
            -out    ${lib.escapeShellArg certPath} \
            -days 825 -batch \
            -subj "/CN=grd-${config.networking.hostName}"
          ${pkgs.coreutils}/bin/chmod 600 ${lib.escapeShellArg certKeyPath}
        fi

        # We do NOT run gnome-keyring-daemon ourselves — SDDM's PAM
        # stack already starts `gnome-keyring-daemon --daemonize --login`
        # for us and registers org.freedesktop.secrets on the user bus.
        # If that's missing, set-credentials will fail and we'll see it
        # in the final status check.

        GRD=${pkgs.gnome-remote-desktop}/bin/grdctl

        # ── 2. Tell grdctl about the cert ─────────────────────────────
        # These two calls return nonzero the first time (cert isnt yet
        # the configured one), but the WRITE succeeds. After this, all
        # subsequent grdctl calls stop spitting the cert error.
        "$GRD" rdp set-tls-cert ${lib.escapeShellArg certPath} || true
        "$GRD" rdp set-tls-key  ${lib.escapeShellArg certKeyPath} || true

        # ── 3. Apply credentials from openbao ────────────────────────
        PW="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg passwordFile})"
        "$GRD" rdp set-credentials ${lib.escapeShellArg user} "$PW" || true

        # ── 4. Port + behaviour ──────────────────────────────────────
        "$GRD" rdp set-port ${toString c.port} || true
        "$GRD" rdp disable-view-only || true
        "$GRD" rdp enable || true

        # ── 5. (Re)start the daemon so the new settings take effect.
        ${pkgs.systemd}/bin/systemctl --user try-restart gnome-remote-desktop.service || true

        # ── 6. Verify end state and fail loudly if anything is off. ──
        # Status output is the same format we read manually with `grdctl
        # status`. Username and Password lines should NOT say "(empty)".
        echo "grd-configure: final status:" >&2
        "$GRD" status >&2 || true

        if "$GRD" status 2>/dev/null | grep -qE "^\s*Status:\s*disabled"; then
          echo "grd-configure: ERROR: RDP backend is disabled after configure" >&2
          exit 1
        fi
        if "$GRD" status 2>/dev/null | grep -qE "^\s*Username:\s*\(empty\)"; then
          echo "grd-configure: ERROR: credentials did not take" >&2
          exit 1
        fi
      '';
    };
  };
}
