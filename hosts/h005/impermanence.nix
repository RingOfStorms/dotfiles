# Impermanence persistence for h005 (router). Most state comes from the shared
# sets in `flakes/impermanence/shared_persistence/`. SSH host keys are already
# persisted by the impermanence module (/persist/etc/ssh).
{ primaryUser, impermanence }:
{ constants, lib, ... }:
let
  shared = impermanence.lib.mergeSharedPersistence (
    with impermanence.sharedPersistence;
    [
      essentials
      hardening
      tailscale
      timezone_cache
      atuin
      zoxide
      tmux
      direnv
      nvim_ros
    ]
  );
in
{
  # Impermanence creates parent directories (`/var/lib/private`) with mode 0755
  # when mounting `/var/lib/private/fleet-edge` or `/var/lib/private/AdGuardHome`,
  # whereas systemd DynamicUser StateDirectory requires `/var/lib/private` to be
  # mode 0700 (`z` adjusts existing directory mode, unlike `d`).
  systemd.tmpfiles.rules = [
    "z /var/lib/private 0700 root root -"
  ];

  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories =
      shared.system.directories
      ++ [
        "/var/lib/secrets_manager_hydrated"
        # DynamicUser owns the private directory; systemd creates the public
        # /var/lib/fleet-edge symlink for SQLite metrics.db at service startup.
        "/var/lib/private/fleet-edge"
        # Expose authority rows (fleet-edge-overrides). Losing them on reboot
        # would orphan the public CNAMEs and o002 vhosts they own.
        {
          directory = "/var/lib/private/fleet-edge-overrides";
          mode = "0700";
        }
        # *.ts.joshuabell.xyz wildcard (private-zone.nix); avoid re-issuing
        # on every boot (Let's Encrypt rate limits).
        {
          directory = "/var/lib/acme";
          user = "acme";
          group = "acme";
          mode = "0755";
        }
        # Preserve DHCP client identity/leases in both bench and router modes.
        {
          directory = "/var/lib/dhcpcd";
          user = "dhcpcd";
          group = "dhcpcd";
          mode = "0750";
        }
      ]
      ++ lib.optionals constants.network.routerEnable [
        {
          directory = "/var/lib/dnsmasq";
          user = "dnsmasq";
          group = "dnsmasq";
          mode = "0755";
        }
        # DynamicUser owns the private directory; systemd creates the public
        # /var/lib/AdGuardHome symlink and adjusts ownership at service startup.
        "/var/lib/private/AdGuardHome"
        {
          directory = "/var/lib/h005-isp-speedtest";
          mode = "0700";
        }
        # NUT recreates its password and runtime files; retain only SSH trust.
        {
          directory = "/root/.ssh";
          mode = "0700";
        }
      ];
    files = shared.system.files ++ [ ];
    users."${primaryUser}" = {
      directories = shared.user.directories ++ [ ];
      files = shared.user.files ++ [ ];
    };
  };
}
