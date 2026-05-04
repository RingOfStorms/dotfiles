# Service constants for gp3 (GPD Pocket 3 - Media/Gaming TV Box)
# Plugged into TV, impermanence-enabled, streams games from joe.
{
  host = {
    name = "gp3";
    primaryUser = "luser";
    stateVersion = "26.05";
  };

  # ── Battery charge manager (smart plug via Home Assistant) ──────────
  # The GPD Pocket 3 has no software charge threshold support, so we
  # automate a smart plug to keep the battery between these bounds.
  batteryManager = {
    hassUrl = "http://10.12.14.22:8123";
    entityId = "switch.smart_plug_b_switch";
    tokenPath = "/var/lib/openbao-secrets/hass_token";
    chargeOnPercent = 30;
    chargeOffPercent = 70;
    checkIntervalMin = 5;
  };

  services = {
    # gnome-remote-desktop (RDP server). Standard RDP port.
    grd = {
      port = 3389;
    };
  };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  secrets = {
    "hass_token" = {
      kvPath = "kv/data/machines/by-host/gp3/hass_token";
      softDepend = [ "battery-manager" ];
    };

    # RDP password used by gnome-remote-desktop (and also fetched on
    # h001 via machines/high-trust/guacamole_gp3_krdp_2026-05-04 for
    # Guacamole). Keeping the secret name as krdp_password for now
    # since switching servers (KRDP → GRD) doesn't change the credential
    # itself; rename later if it gets confusing.
    "krdp_password" = {
      kvPath = "kv/data/machines/by-host/gp3/krdp_password";
      owner = "luser";
      group = "users";
      # Configurator unit lives in the user systemd manager, so a
      # softDepend on a system unit name doesn't apply here. We just
      # make sure the file exists; vault-agent path units take care
      # of re-rendering on change.
    };
  };
}
