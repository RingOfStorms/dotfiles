# Tailnet + LAN DNS records served by h005's dnsmasq (ROUTING-PLAN §8 step 4).
#
# Container routes are generated from containers/*/service.nix by
# containers/lib.nix `dnsRecords` (read from this repo's working tree at
# build time). Only names that aren't container routes yet
# are listed here by hand. Converting a service to `routes` means deleting
# its names below; the eval refuses a name that is both.
{ fleet }:
let
  domain = fleet.global.domain;
  h001 = fleet.hosts.h001;
  generated = (import ../../containers/lib.nix).dnsRecords {
    dir = ../../containers;
    inherit (fleet) hosts;
  };

  # notes is a generated route now (containers/trilium). sso-proxy is the
  # fleet oauth2-proxy's sign-in host on h005 (oauth2-proxy.nix); tailnet
  # record here, plus a public CNAME to o002 below (ROUTING-PLAN §8 step 6:
  # o002's vhost proxies only /oauth2/ to h005's edge listener).
  handTailnet = [
    {
      fqdn = "sso-proxy.${domain}";
      ip = fleet.hosts.h005.overlayIp;
      source = "hand (h005/oauth2-proxy.nix)";
    }
    {
      fqdn = "fleet.${domain}";
      ip = fleet.hosts.h005.overlayIp;
      source = "hand (h005/fleet-edge.nix)";
    }
    # Fully-qualified tailnet alias. ~joshuabell.xyz split DNS wins over
    # MagicDNS's net.joshuabell.xyz zone, so it has to be answered here.
    {
      fqdn = "secrets.h001.net.${domain}";
      ip = h001.overlayIp;
      source = "hand (h005/dns-records.nix)";
    }
  ];

  merge =
    what: gen: hand:
    let
      genNames = map (r: r.fqdn) gen;
      clash = builtins.filter (r: builtins.elem r.fqdn genNames) hand;
    in
    if clash != [ ] then
      throw "h005/dns-records.nix: ${what} ${(builtins.head clash).fqdn} is generated from containers now; delete the hand entry"
    else
      gen ++ hand;
in
{
  tailnet = merge "tailnet" generated.tailnet handTailnet;
  # No hand LAN names left (trilium is tailnet-only; arr is generated).
  lan = generated.lan;
  public = generated.public;

  # Desired bunny zone for `fleet-edge dns-plan` (ROUTING-PLAN §8 step 4).
  # Generated route CNAMEs plus the hand-kept public names below. Records
  # in the zone that are neither are reported as unmanaged, never deleted.
  publicSpec =
    let
      ttl = 300;
      cname = target: n: {
        name = n;
        type = "CNAME";
        value = "${target}.${domain}";
        inherit ttl;
        source = "hand (h005/dns-records.nix)";
      };
      gen = map (r: {
        name = builtins.replaceStrings [ ".${domain}" ] [ "" ] r.fqdn;
        type = r.type;
        value = r.target;
        inherit ttl;
        inherit (r) source;
      }) generated.public;
      hand = [
        {
          name = "o002";
          type = "A";
          value = fleet.hosts.o002.publicIp;
          inherit ttl;
          source = "hand (edge anchor)";
        }
        {
          name = "headscale";
          type = "A";
          value = fleet.hosts.o002.publicIp;
          inherit ttl;
          source = "hand (headscale on o002)";
        }
      ]
      # o002 hand vhosts (hosts/oracle/o002/nginx.nix).
      ++ map (cname "o002") [
        "www"
        "computerboyz"
        # Public sign-in for auth = oauth2-proxy routes (ROUTING-PLAN §8
        # step 6); o002 proxies only /oauth2/ to h005's edge listener.
        "sso-proxy"
      ]
      # minecraft: router path (step 4, router forwards).
      ++ map (cname "home") [ "minecraft" ]
      # *.share: local temporary sharing (FLOWS-AUDIT.md §c, fleet-share-serve).
      ++ map (cname "o002") [ "*.share" ];
      genNames = map (r: r.name) gen;
      clash = builtins.filter (r: builtins.elem r.name genNames) hand;
    in
    if clash != [ ] then
      throw "h005/dns-records.nix: public ${(builtins.head clash).name} is generated from containers now; delete the hand entry"
    else
      {
        zone = domain;
        records = gen ++ hand;
        # home's A record is written by the DDNS timer (mods/ddns.nix).
        external = [ "home" ];
        # Deleted by `fleet-edge dns-plan --apply` only while the live record
        # matches name, type and value exactly (else: retire-mismatch, no
        # writes at all). Retired 2026-10-21: dead services and old hosts;
        # docs leaked h001's overlay IP publicly. Keep entries until a later
        # plan shows them gone, then they can be dropped from this list.
        retire = [
          {
            name = "docs";
            type = "A";
            value = "100.64.0.13";
          }
          {
            name = "l001";
            type = "A";
            value = "172.236.111.33";
          }
          {
            name = "o001";
            type = "A";
            value = "64.181.210.7";
          }
        ]
        ++
          map
            (name: {
              inherit name;
              type = "CNAME";
              value = "o002.${domain}";
            })
            [
              "element"
              "etebase"
              "kura"
              "matrix"
              "n8n"
              "pim"
              # trilium made tailnet-only 2026-10-21.
              "notes"
              # kavita made tailnet-only 2026-10-21.
              "books"
            ];
      };
}
