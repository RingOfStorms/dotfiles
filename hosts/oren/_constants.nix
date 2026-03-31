# Service constants for oren (Framework Laptop)
# Primarily a desktop/dev machine. Minimal services.
{
  host = {
    name = "oren";
    overlayIp = "100.64.0.5";
    primaryUser = "josh";
    stateVersion = "25.05";
  };

  services = {
    sunshine = {
      port = 47989; # base port; web UI at +1 (47990)
    };
  };
}
