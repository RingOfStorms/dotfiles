# Host-level support for floating containers on h003.
# The containers host module (inputs.containers.nixosModules.default) provides
# nginx with the runtime include dir, runtime firewall ports, extra-container
# and podman. Services themselves are deployed with `containers`,
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

  # Impermanent root: keep container data, runtime unit links, runtime
  # firewall ports/nginx includes and podman's image store across reboots.
  environment.persistence."/persist".directories = [
    "/srv/containers"
    "/etc/systemd-mutable"
    "/var/lib/fleet-containers"
    "/var/lib/containers"
    "/var/lib/nixos-containers"
    # extra-container <name>.conf links, read via EnvironmentFile by container@ units.
    "/etc/nixos-containers"
  ];

  # /etc/systemd-mutable is bind-mounted from /persist after PID 1 has loaded
  # units, so the container@<svc> links in machines.target.wants are missed at
  # boot. Reload once the bind is up and start every wanted container
  # (`containers stop` removes the link, so stopped services stay stopped).
  systemd.services.fleet-containers-boot-start = {
    description = "Start persisted floating containers after /persist binds";
    wantedBy = [ "multi-user.target" ];
    after = [
      "local-fs.target"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = [ "/etc/systemd-mutable" ];
    serviceConfig.Type = "oneshot";
    script = ''
      systemctl daemon-reload
      for l in /etc/systemd-mutable/system/machines.target.wants/*.service; do
        [ -e "$l" ] || continue
        echo "starting $(basename "$l")"
        systemctl start --no-block "$(basename "$l")"
      done
    '';
  };
}
