# C1: the container runs with privateUsers = "identity" (its own user
# namespace) and keeps only CAP_NET_ADMIN (flake.nix), which the firewall
# needs to load arr-lo-guard below. The VPN (VPN-Confinement/wg) and
# torrents are gone. No app needs NET_ADMIN. jellyfin, sonarr, radarr
# and recyclarr already get an empty bounding set and
# NoNewPrivileges from their NixOS modules; these are the units that ran with
# the full inherited set. No ProtectSystem=strict: they write state and the
# NFS media tree.
{ lib, ... }:
let
  # Loopback guard (C1). The *arr APIs trust local addresses
  # (DisabledForLocalAddresses) and sabnzbd whitelists 10.233/16, so any
  # process in the guest could drive them. New TCP connections from this
  # guest to its own addresses (127/8, ::1, 10.233.16.2) on these ports
  # are allowed only for the listed uids; everyone else (jellyfin, kavita,
  # shelfmark, media-integrity, and seerr outside 8989/7878) gets a reset.
  # Host nginx arrives via the veth (INPUT), so it is unaffected.
  # uids: 0 root (*-api oneshots), 38 sabnzbd, 232 bazarr, 262 seerr,
  # 269 recyclarr, 274 sonarr, 275 radarr, 293 prowlarr.
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
    ]
    + setup "ip6tables" [
      "-m addrtype --dst-type LOCAL"
    ];
  networking.firewall.extraStopCommands = teardown "iptables" + teardown "ip6tables";

  systemd.services =
    lib.genAttrs
      [
        "bazarr"
        "kavita"
        "prowlarr"
        "seerr"
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
