{
  constants,
  pkgs,
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
    DynamicUser = false;
    User = "ollama";
    Group = "ollama";
  };

  users.users.ollama = {
    isSystemUser = true;
    group = "ollama";
    home = "/var/lib/ollama";
  };
  users.groups.ollama = {};

  # Allow access from Tailscale overlay and LAN
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
  networking.firewall.allowedTCPPorts = [ c.port ];
}
