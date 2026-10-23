# C1: the container keeps CAP_SYS_ADMIN/NET_ADMIN (flake.nix) for
# VPN-Confinement (wg.service, `ip netns`), and its root is host root
# (privateUsers = "no"). No app needs any of that. jellyfin, sonarr, radarr,
# transmission and recyclarr already get an empty bounding set and
# NoNewPrivileges from their NixOS modules; these are the units that ran with
# the full inherited set. No ProtectSystem=strict: they write state and the
# NFS media tree.
{ lib, ... }:
let
  # Loopback guard (C1). The *arr APIs trust local addresses
  # (DisabledForLocalAddresses), transmission has no rpc auth and sabnzbd
  # whitelists 10.233/16, so any process in the guest could drive them.
  # New TCP connections from this guest to its own addresses (127/8, ::1,
  # 10.233.16.2, wg-br) or to the wg netns (192.168.15.0/24) on these ports
  # are allowed only for the listed uids; everyone else (jellyfin, kavita,
  # shelfmark, media-integrity, and seerr outside 8989/7878) gets a reset.
  # Host nginx arrives via the veth (INPUT), so it is unaffected.
  # uids: 0 root (*-api oneshots), 38 sabnzbd, 232 bazarr, 262 seerr,
  # 269 recyclarr, 274 sonarr, 275 radarr, 293 prowlarr,
  # 960 transmission-rpc-fwd (container.nix).
  guarded = {
    "8989" = [
      0
      274
      293
      232
      262
      269
    ]; # sonarr
    "7878" = [
      0
      275
      293
      232
      262
      269
    ]; # radarr
    "9696" = [
      0
      293
      274
      275
    ]; # prowlarr (sonarr/radarr fetch indexers)
    "6767" = [
      0
      232
    ]; # bazarr
    "6336" = [
      0
      38
      274
      275
    ]; # sabnzbd
    "9091" = [
      0
      274
      275
      960
    ]; # transmission rpc (socat + wg netns)
  };
  chain = "arr-lo-guard";
  rulesFor =
    ipt: dests:
    lib.concatStrings (
      lib.mapAttrsToList (
        port: uids:
        lib.concatMapStrings (
          dst:
          lib.concatMapStrings (
            uid:
            "${ipt} -A ${chain} ${dst} -p tcp --dport ${port} -m owner --uid-owner ${toString uid} -j RETURN\n"
          ) uids
          + "${ipt} -A ${chain} ${dst} -p tcp --dport ${port} -j REJECT --reject-with tcp-reset\n"
        ) dests
      ) guarded
    );
  setup = ipt: dests: ''
    ${ipt} -N ${chain} 2>/dev/null || ${ipt} -F ${chain}
    ${ipt} -D OUTPUT -m conntrack --ctstate NEW -j ${chain} 2>/dev/null || true
    ${ipt} -I OUTPUT -m conntrack --ctstate NEW -j ${chain}
    ${rulesFor ipt dests}
  '';
  teardown = ipt: ''
    ${ipt} -D OUTPUT -m conntrack --ctstate NEW -j ${chain} 2>/dev/null || true
    ${ipt} -F ${chain} 2>/dev/null || true
    ${ipt} -X ${chain} 2>/dev/null || true
  '';
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
  networking.firewall.extraCommands =
    setup "iptables" [
      "-m addrtype --dst-type LOCAL"
      "-d 192.168.15.0/24"
    ]
    + setup "ip6tables" [
      "-m addrtype --dst-type LOCAL"
      "-d fd93:9701:1d00::/64"
    ];
  networking.firewall.extraStopCommands = teardown "iptables" + teardown "ip6tables";

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
