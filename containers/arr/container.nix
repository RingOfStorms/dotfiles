# Guest config. Reuses the h001 modules (single source of truth) and pins
# every uid/gid that appears in migrated state, since the guest's dynamic
# allocation would otherwise differ from the host's.
{
  lib,
  pkgs,
  nixarr,
  constants,
  fleet,
  ...
}:
{
  imports = [
    nixarr.nixosModules.default
    ../../hosts/h001/mods/nixarr.nix
    ../../hosts/h001/mods/kavita.nix
    ../../hosts/h001/mods/media-integrity.nix
    ../../hosts/h001/mods/hardware-transcoding.nix
  ];

  system.stateVersion = constants.host.stateVersion;
  nixpkgs.config.allowUnfree = true; # unrar, intel firmware

  # Was a sec-agent configChange on the host; the secret is bound in read-only.
  nixarr.vpn.wgConf = "${fleet.global.secretsDir}/us_chi_wg_2026-03-15";

  # The guest has no nginx; the host keeps the vhosts.
  services.nginx.enable = lib.mkForce false;

  # Host already forwards (NAT for ve-*); boot.kernel.sysctl doesn't apply
  # inside nspawn.
  boot.kernel.sysctl = lib.mkForce { };

  # transmission runs with RootDirectory=/run/transmission and BindPaths=/run.
  # Under nspawn systemd also stages os-release into /run/host inside that
  # root, which is read-only there (226/NAMESPACE). An empty tmpfs on
  # /run/host gives it a writable place.
  systemd.services.transmission.serviceConfig.TemporaryFileSystem = [ "/run/host" ];

  # Pinned to the values on h001 before the move (state and secrets are
  # owned by these numbers).
  users.users.kavita.uid = 982;
  users.groups.kavita.gid = 970;
  users.users.media-integrity.uid = 980;
  users.groups.media-integrity.gid = 969;
  users.groups = {
    sonarr-api.gid = 977;
    sabnzbd-api.gid = 978;
    radarr-api.gid = 979;
    prowlarr-api.gid = 980;
    bazarr-api.gid = 983;
    transmission-api.gid = 976;
    seerr-api.gid = 972;
  };
}
