# Eval test for lib.nix webSourcesByHost (ROUTING-PLAN §8 step 2), the
# per-host 80/443 source allow-list. Run from the repo root:
#   nix eval --impure --expr 'import ./containers/tests/web-sources.nix'
# Returns the computed map, or throws on the first failed check.
let
  lib = import ../lib.nix;
  hosts = (import ../../hosts/fleet.nix).hosts;
  ws = lib.webSourcesByHost {
    dir = ../.;
    inherit hosts;
  };
  # The only hand-written tailnet vhost left is h001's arr (mods/
  # arr-nginx.nix), which is why h001 passes extraWebSources.
  h001Extra = lib.webSourcesByHost {
    dir = ../.;
    inherit hosts;
    extra.h001 = {
      tailnet = [
        "100.64.0.0/10"
        "fd7a:115c:a1e0::/48"
      ];
    };
  };
  # A tailnet route with an explicit `allow` list admits only those hosts.
  narrowed = lib.webSourcesByHost {
    dir = ../.;
    inherit hosts;
    extra.joe = { };
  };
  names = builtins.attrNames ws;
  checks = [
    {
      ok =
        names == [
          "h001"
          "h003"
          "joe"
        ];
      msg = "hosts with web sources: ${builtins.toJSON names} (only hosts with http routes)";
    }
    {
      ok = ws.h001.tailnet == [ "100.64.0.0/10" ] && ws.h003.tailnet == [ "100.64.0.0/10" ];
      msg = "a route without `allow` admits the whole tailnet: ${
        builtins.toJSON {
          h001 = ws.h001;
          h003 = ws.h003;
        }
      }";
    }
    {
      ok =
        ws.joe.tailnet == [
          "100.64.0.1"
          "100.64.0.13"
          "100.64.0.15"
          "100.64.0.18"
          "100.64.0.2"
        ];
      msg = "joe's routes name their hosts via `allow`, so only those overlay IPs: ${builtins.toJSON ws.joe.tailnet}";
    }
    {
      ok = ws.h001.lan && !ws.h003.lan && !ws.joe.lan;
      msg = "lan flag: h001 has a lan route, h003 and joe do not: ${
        builtins.toJSON {
          h001 = ws.h001.lan;
          h003 = ws.h003.lan;
          joe = ws.joe.lan;
        }
      }";
    }
    {
      ok = !(ws ? lio) && !(ws ? h004) && !(ws ? h005);
      msg = "hosts without http routes are absent, not empty: ${builtins.toJSON names}";
    }
    {
      ok = builtins.all (h: builtins.all (s: lib.validWebSource s) ws.${h}.tailnet) names;
      msg = "every emitted source is a valid v4/v6 literal or CIDR";
    }
    {
      ok =
        h001Extra.h001.tailnet == [
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
        ]
        && h001Extra.h003 == ws.h003;
      msg = "extraWebSources merges additively and leaves other hosts alone: ${builtins.toJSON h001Extra.h001.tailnet}";
    }
    {
      ok = narrowed.joe.tailnet == ws.joe.tailnet;
      msg = "an empty extra does not change a host";
    }
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
  ];
  bad = builtins.filter (c: !c.ok) checks;
in
if bad == [ ] then ws else throw "web-sources: ${(builtins.head bad).msg}"
