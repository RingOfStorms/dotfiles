# C1: the container keeps CAP_SYS_ADMIN/NET_ADMIN (flake.nix) for
# VPN-Confinement (wg.service, `ip netns`), and its root is host root
# (privateUsers = "no"). No app needs any of that. jellyfin, sonarr, radarr,
# transmission and recyclarr already get an empty bounding set and
# NoNewPrivileges from their NixOS modules; these are the units that ran with
# the full inherited set. No ProtectSystem=strict: they write state and the
# NFS media tree.
{ lib, ... }:
let
  noCaps = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = lib.mkForce "";
    AmbientCapabilities = lib.mkForce "";
    RestrictSUIDSGID = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    LockPersonality = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@mount"
    ];
  };
in
{
  systemd.services =
    lib.genAttrs
      [
        "bazarr"
        "kavita"
        "prowlarr"
        "seerr"
        "transmission-rpc-forward"
        "media-integrity-scan"
      ]
      (_: {
        serviceConfig = noCaps;
      })
    // {
      # sabnzbd's ExecStartPre runs as sabnzbd:media and does
      # `install -o sabnzbd -g media` onto its own file: a chown to its own
      # uid/gid, which needs no CAP_CHOWN but does need the syscall, and
      # @chown sits inside @privileged. Later entries override earlier ones.
      sabnzbd.serviceConfig = noCaps // {
        SystemCallFilter = noCaps.SystemCallFilter ++ [ "@chown" ];
      };
    };
}
