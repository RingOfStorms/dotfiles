# Eval test for lib.nix edgeVirtualHosts (ROUTING-PLAN §8 step 3), the
# generated public edge (o002). Run from the repo root:
#   nix eval --impure --expr 'import ./containers/tests/edge-vhosts.nix'
# Returns the list of generated names, or throws on the first failed check.
let
  lib = import ../lib.nix;
  hosts = (import ../../hosts/fleet.nix).hosts;
  v = lib.edgeVirtualHosts {
    dir = ../.;
    inherit hosts;
  };
  names = builtins.attrNames v;
  # Every public route with via = edge today; adding one must update this.
  expected = [
    "atuin.joshuabell.xyz"
    "chat.joshuabell.xyz"
    "gist.joshuabell.xyz"
    "git.joshuabell.xyz"
    "jellyfin.joshuabell.xyz"
    "life.joshuabell.xyz"
    "location.joshuabell.xyz"
    "media.joshuabell.xyz"
    "photos.joshuabell.xyz"
    "puzzles.joshuabell.xyz"
    "secrets.joshuabell.xyz"
    "sso.joshuabell.xyz"
    "vault.joshuabell.xyz"
  ];
  loc = n: v.${n}.locations."/";
  has =
    n: s:
    builtins.match ".*${s}.*" (builtins.replaceStrings [ "\n" ] [ " " ] (loc n).extraConfig) != null;
  checks = [
    {
      ok = names == expected;
      msg = "names: ${builtins.toJSON names}";
    }
    {
      ok =
        !(v ? "docs.joshuabell.xyz")
        && !(v ? "litellm.joshuabell.xyz")
        && !(v ? "books.joshuabell.xyz")
        && !(v ? "notes.joshuabell.xyz");
      msg = "tailnet routes must not reach the edge";
    }
    {
      ok = builtins.all (n: (loc n).proxyPass == "http://100.64.0.13:8443") names;
      msg = "every h001 route proxies to the edge listener 100.64.0.13:8443";
    }
    {
      ok = builtins.all (n: v.${n}.enableACME && v.${n}.forceSSL) names;
      msg = "per-name ACME + forceSSL by default";
    }
    {
      ok =
        has "life.joshuabell.xyz" "proxy_request_buffering off;"
        && has "life.joshuabell.xyz" "proxy_read_timeout 1h;";
      msg = "life streams uploads with 1h timeouts";
    }
    {
      ok = has "photos.joshuabell.xyz" "client_max_body_size 100G;";
      msg = "photos maxBody";
    }
  ];
  bad = builtins.filter (c: !c.ok) checks;
in
if bad == [ ] then names else throw "edge-vhosts: ${(builtins.head bad).msg}"
