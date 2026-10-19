# Impermanence persistence for h005 (router). Most state comes from the shared
# sets in `flakes/impermanence/shared_persistence/`. SSH host keys are already
# persisted by the impermanence module (/persist/etc/ssh).
{ primaryUser, impermanence_mod }:
{ constants, lib, ... }:
let
  shared = impermanence_mod.lib.mergeSharedPersistence (
    with impermanence_mod.sharedPersistence;
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
  systemd.tmpfiles.rules = lib.optionals constants.network.routerEnable [
    "d /var/lib/private 0700 root root -"
  ];

  environment.persistence."/persist" = {
    enable = true;
    hideMounts = true;
    directories = shared.system.directories ++ [
      "/var/lib/secrets_manager_hydrated"
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
    ] ++ lib.optionals constants.network.routerEnable [
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
