# Guest config. Host network: atuin on 127.0.0.1:8888; postgres on its unix
# socket only (the host's own postgres already owns 127.0.0.1:5432).
{ pkgs, lib, ... }:
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
    host = "127.0.0.1";
    port = 8888;
  };
}
