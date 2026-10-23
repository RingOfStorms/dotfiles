# Guest config. The media stack lives here (nixarr.nix, kavita.nix,
# media-integrity.nix); h001 only keeps the nginx vhosts. It pins
# every uid/gid that appears in migrated state, since the guest's dynamic
# allocation would otherwise differ from the host's.
{
  config,
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
    ./nixarr.nix
    ./kavita.nix
    ./media-integrity.nix
    ./hardening.nix
    ../../hosts/h001/mods/hardware-transcoding.nix
  ];

  system.stateVersion = constants.host.stateVersion;
  nixpkgs.config.allowUnfree = true; # unrar, intel firmware

  # Was a sec-agent configChange on the host; the secret is bound in read-only.
  nixarr.vpn.wgConf = "${fleet.global.secretsDir}/us_chi_wg_2026-03-15";

  # The guest has no nginx; the host vhosts are routes (service.nix).
  services.nginx.enable = lib.mkForce false;

  # boot.kernel.sysctl doesn't apply inside nspawn (read-only /proc/sys);
  # with net.private the guest has its own netns and /proc/sys/net is
  # writable, so the forwarding VPN-Confinement needs (veth -> wg netns DNAT
  # for transmission's rpc) is set by a unit before the netns comes up.
  boot.kernel.sysctl = lib.mkForce { };
  systemd.services.guest-ip-forward = {
    description = "net.ipv4.ip_forward=1 in the guest netns (wg port mapping)";
    wantedBy = [ "multi-user.target" ];
    before = [ "wg.service" ];
    requiredBy = [ "wg.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.procps}/bin/sysctl -w net.ipv4.ip_forward=1";
    };
  };
  # privateUsers = "identity" (C1): `ip netns exec` and `ip -n` remount /sys
  # for the target netns, which a user-namespaced nspawn guest may not do
  # (nspawn's /sys has locked overmounts). nsenter --net only switches the
  # netns, which is all these calls need, so run VPN-Confinement's own up
  # script with those two forms rewritten.
  systemd.services.wg.serviceConfig.ExecStart =
    let
      vpnUp = import "${nixarr.inputs.vpnconfinement}/modules/vpn-up.nix" {
        inherit pkgs lib;
        optionalIPv6String = lib.optionalString config.networking.enableIPv6;
      };
      orig = vpnUp "wg" config.vpnNamespaces.wg;
      patched = pkgs.runCommand "wg-up-userns" { } ''
        mkdir -p $out/bin
        sed -E \
          -e 's#ip netns exec ([a-z]+) #${pkgs.util-linux}/bin/nsenter --net=/run/netns/\1 -- #g' \
          -e 's#ip (-[46] )?-n ([a-z]+) #${pkgs.util-linux}/bin/nsenter --net=/run/netns/\2 -- ip \1#g' \
          ${orig}/bin/wg-up > $out/bin/wg-up
        chmod +x $out/bin/wg-up
        ! grep -qE 'ip netns exec|ip (-[46] )?-n ' $out/bin/wg-up
      '';
    in
    lib.mkForce "${patched}/bin/wg-up";
  # sonarr/radarr store transmission as localhost:9091 (their DB). Before
  # net.private the host nginx answered there; now a guest-local forward
  # into the wg netns does. Host nginx reaches 9091 via the VPN-Confinement
  # DNAT on the guest veth instead.
  systemd.services.transmission-rpc-forward = {
    description = "127.0.0.1:9091 -> transmission rpc in the wg netns";
    wantedBy = [ "multi-user.target" ];
    after = [ "wg.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:9091,bind=127.0.0.1,reuseaddr,fork TCP:192.168.15.1:9091";
      Restart = "always";
      # Static uid so the loopback guard (hardening.nix) can match it.
      User = "transmission-rpc-fwd";
      Group = "transmission-rpc-fwd";
    };
  };
  users.users.transmission-rpc-fwd = {
    isSystemUser = true;
    uid = 960;
    group = "transmission-rpc-fwd";
  };
  users.groups.transmission-rpc-fwd.gid = 960;

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
