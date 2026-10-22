# Guest config. Private network (service.nix net): atuin on :8888; postgres on its unix
# socket only.
{
  pkgs,
  lib,
  fleetNet,
  ...
}:
{
  system.stateVersion = "24.11";

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17.withJIT;
    enableJIT = true;
    dataDir = "/var/lib/postgresql/17";
    settings.listen_addresses = lib.mkForce "";
    authentication = lib.mkForce ''
      local all all trust
    '';
  };

  services.atuin = {
    enable = true;
    openRegistration = false;
    openFirewall = false;
    host = fleetNet.bindAddress;
    port = 8888;
  };
}
