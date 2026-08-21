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
    tokenPath = "/var/lib/secrets_manager_hydrated/hass_token";
    chargeOnPercent = 30;
    chargeOffPercent = 70;
    checkIntervalMin = 5;
  };

  services = { };
}
