# Container DNS answers come from h005's runtime placement registry.
# This file declares route names and public membership, not placement.
# Hand-kept host names must not overlap container routes.
{ fleet }:
let
  domain = fleet.global.domain;
  h001 = fleet.hosts.h001;
  generated = (import ../../containers/lib.nix).dnsRecords {
    dir = ../../containers;
  };

  # The sign-in name has a tailnet answer here and a public CNAME to o002;
  # o002 forwards only /oauth2/ to h005's edge listener.
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
    # tmux-agents-mobile on lio (hosts/lio/tmux-mobile.nix): tailnet-only, no
    # public record and no container route, so it is answered here and nowhere
    # else.
    {
      fqdn = "tmux.${domain}";
      ip = fleet.hosts.lio.overlayIp;
      source = "hand (lio/tmux-mobile.nix)";
    }
  ];

  merge =
    what: gen: hand:
    let
      genNames = map (r: r.fqdn) generated.names;
      clash = builtins.filter (r: builtins.elem r.fqdn genNames) hand;
    in
    if clash != [ ] then
      throw "h005/dns-records.nix: ${what} ${(builtins.head clash).fqdn} is generated from containers now; delete the hand entry"
    else
      gen ++ hand;
in
{
  names = generated.names;
  tailnet = merge "tailnet" [ ] handTailnet;
  lan = [ ];
  public = generated.public;

  # The reconciler filters route CNAMEs by effective placement. Unmanaged
  # records are reported, never deleted.
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
        inherit (r) source service;
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
        # Router anchor (via = router CNAMEs). The value is h005's WAN IPv4,
        # resolved and written only by the ddns-update timer
        # (mods/ddns.nix, `fleet-edge ddns`); dns-plan reports it, never
        # writes it.
        {
          name = "home";
          type = "A";
          dynamic = "wan-ipv4";
          inherit ttl;
          source = "hand (router WAN, ddns-update)";
        }
      ]
      # o002 hand vhosts (hosts/oracle/o002/nginx.nix).
      ++ map (cname "o002") [
        "www"
        # o002 exposes only /oauth2/ on h005's edge listener.
        "sso-proxy"
      ]
      # Wildcard names support temporary local sharing.
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
        # Deleted by `fleet-edge dns-plan --apply` only while the live record
        # matches name, type and value exactly (else: retire-mismatch, no
        # writes at all). Drop an entry once a plan shows its record gone.
        # Entries: { name; type; value; }.
        retire = [ ];
      };
}
