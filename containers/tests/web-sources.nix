# Eval test for lib.nix webSourcesIps, splitting explicit web sources by family.
# Run from the repo root:
#   nix eval --impure --expr 'import ./containers/tests/web-sources.nix'
# Returns true, or throws on the first failed check.
let
  lib = import ../lib.nix;
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
  ];
  bad = builtins.filter (c: !c.ok) checks;
in
if bad == [ ] then true else throw "web-sources: ${(builtins.head bad).msg}"
