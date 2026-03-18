{
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.ollama;
in
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    host = "0.0.0.0";
    port = c.port;
  };

  # Disable DynamicUser so /var/lib/ollama can be a direct bind mount
  # (impermanence bind mounts conflict with systemd's DynamicUser /var/lib/private setup)
  systemd.services.ollama.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "ollama";
    Group = "ollama";
  };

  users.users.ollama = {
    isSystemUser = true;
    group = "ollama";
    home = "/var/lib/ollama";
  };
  users.groups.ollama = {};

  # Ensure models subdirectory exists before ollama starts
  # (ProtectSystem=strict + ReadWritePaths needs it to exist for mount namespacing)
  systemd.tmpfiles.rules = [
    "d /var/lib/ollama/models 0700 ollama ollama -"
  ];

  # Allow access from Tailscale overlay and LAN
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
  networking.firewall.allowedTCPPorts = [ c.port ];
}
