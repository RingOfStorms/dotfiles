# Host-level support for floating containers on h003.
# The containers host module (inputs.containers.nixosModules.default) provides
# nginx with the runtime include dir, runtime firewall ports, extra-container
# and podman. Services themselves (minecraft, ...) are deployed with `containers`,
# not by rebuilding this host. See containers/README.md.
{ ... }:
{
  ringofstorms.containers.nginx.enable = true;

  # Per-service nginx sites (written by `containers deploy`) listen on the
  # tailscale overlay IP. Wait for tailscale to have its address;
  # IPFreeBind lets nginx bind even if it races.
  systemd.services.nginx = {
    wants = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    after = [
      "network-online.target"
      "tailscaled-autoconnect.service"
    ];
    serviceConfig.IPFreeBind = true;
  };

  environment.shellAliases = {
    mc-attach = "sudo nixos-container run minecraft -- tmux attach -t mc";
  };
}
