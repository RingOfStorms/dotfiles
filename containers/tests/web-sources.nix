# Eval test for lib.nix webSourcesIps, splitting explicit web sources by family.
# Run from the repo root:
#   nix eval --impure --expr 'import ./containers/tests/web-sources.nix'
# Returns true, or throws on the first failed check.
let
  lib = import ../lib.nix;
  hosts = {
    lio = { trust = "high"; overlayIp = "100.64.0.1"; overlayIp6 = "fd7a:115c:a1e0::1"; };
    edge = { trust = "high"; overlayIp = "100.64.0.5"; overlayIp6 = "fd7a:115c:a1e0::5"; };
    low = { trust = "low"; overlayIp = "100.64.0.6"; overlayIp6 = "fd7a:115c:a1e0::6"; };
    offline = { trust = "high"; };
  };
  checks = [
    {
      ok =
        lib.webSourcesIps {
          sources = [
            "100.64.0.0/10"
            "fd7a:115c:a1e0::/48"
            "10.12.14.0/24"
          ];
          family = "v4";
        } == [
          "100.64.0.0/10"
          "10.12.14.0/24"
        ];
      msg = "webSourcesIps v4 split: v4 literals and CIDRs only";
    }
    {
      ok =
        lib.webSourcesIps {
          sources = [
            "100.64.0.0/10"
            "fd7a:115c:a1e0::/48"
            "10.12.14.0/24"
          ];
          family = "v6";
        } == [ "fd7a:115c:a1e0::/48" ];
      msg = "webSourcesIps v6 split: v6 literals and CIDRs only";
    }
    {
      ok = lib.firewallHighTrustIps6 { inherit hosts; exclude = [ "edge" ]; } == [ hosts.lio.overlayIp6 ];
      msg = "IPv6 high-trust sources must exclude low trust, excluded hosts and missing addresses";
    }
    {
      ok = (lib.sshGuardAssertion {
        inherit hosts;
        host = "test";
        ips = [ hosts.lio.overlayIp ];
        ips6 = [ hosts.lio.overlayIp6 ];
      }).assertion;
      msg = "SSH guard accepts lio in both families";
    }
    {
      ok = !(lib.sshGuardAssertion {
        inherit hosts;
        host = "test";
        ips = [ hosts.lio.overlayIp ];
        ips6 = [ hosts.edge.overlayIp6 ];
      }).assertion;
      msg = "SSH guard rejects missing lio IPv6 even with valid IPv4";
    }
    {
      ok = lib.tailnetExcludedOverlayIps6 (hosts // { o002 = hosts.edge; }) == [ hosts.low.overlayIp6 hosts.edge.overlayIp6 ];
      msg = "IPv6 HTTP exclusions include low-trust peers and o002";
    }
  ];
  bad = builtins.filter (c: !c.ok) checks;
in
if bad == [ ] then true else throw "web-sources: ${(builtins.head bad).msg}"
