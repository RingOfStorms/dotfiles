# Guest config. The media stack lives here (nixarr.nix, kavita.nix,
# media-integrity.nix); h001 only keeps the nginx vhosts. It pins
# every uid/gid that appears in migrated state, since the guest's dynamic
# allocation would otherwise differ from the host's.
{
  lib,
  nixarr,
  constants,
  ...
}:
{
  imports = [
    nixarr.nixosModules.default
    ./nixarr.nix
    ./kavita.nix
    ./media-integrity.nix
    ./hardening.nix
    ../../hosts/h001/mods/hardware-transcoding.nix
  ];

  system.stateVersion = constants.host.stateVersion;
  nixpkgs.config.allowUnfree = true; # unrar, intel firmware

  # The guest has no nginx; the host vhosts are routes (service.nix).
  services.nginx.enable = lib.mkForce false;

  # boot.kernel.sysctl doesn't apply inside nspawn (read-only /proc/sys).
  boot.kernel.sysctl = lib.mkForce { };

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
    seerr-api.gid = 972;
  };
}
