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
    krdp = {
      port = 3389;
    };
  };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  secrets = {
    "hass_token" = {
      kvPath = "kv/data/machines/by-host/gp3/hass_token";
      softDepend = [ "battery-manager" ];
    };

    # Password for the KRDP user systemd unit. The same value should
    # also live at machines/high-trust/guacamole_gp3_krdp_2026-05-04
    # (rendered on h001) so Guacamole can connect.
    "krdp_password" = {
      kvPath = "kv/data/machines/by-host/gp3/krdp_password";
      owner = "luser";
      group = "users";
      softDepend = [ "krdpserver" ];
    };
  };
}
