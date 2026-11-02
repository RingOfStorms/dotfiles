# Eval test for lib.nix normalizeNet with kind = "podman": net.uses/net.egress
# mean the same as for nixos guests (the ports-file lines key on the static
# fleet-noinet IP, cli/routes.go netExceptions), and the bridge has no
# internet path, so a private podman service needs internet = false.
# Run from the repo root:
#   nix eval --impure --expr 'import ./containers/tests/podman-net.nix'
# Returns true, or throws on the first failed check.
let
  lib = import ../lib.nix;
  ok = value: (builtins.tryEval (builtins.deepSeq (lib.normalize value) true)).success;
  pod = net: {
    name = "gist";
    kind = "podman";
    internet = false;
    net = {
      private = true;
      index = 2;
    }
    // net;
  };
  full =
    (lib.normalize (pod {
      uses = [ "litellm.web" ];
      egress = [ "10.12.14.181:9010/tcp" ];
    })).net;
  services = lib.allServices ../.;
  privPods = builtins.filter (s: s.kind == "podman" && s.net.private) services;
  checks = [
    {
      ok =
        full == {
          private = true;
          index = 2;
          ip = "10.89.250.102";
          uses = [ "litellm.web" ];
          egress = [ "10.12.14.181:9010/tcp" ];
        };
      msg = "podman uses/egress are kept, keyed on the static bridge IP";
    }
    {
      ok =
        !(ok (pod {
          uses = [ "litellm" ];
        }));
      msg = "podman uses must be <service>.<route>";
    }
    {
      ok =
        !(ok (pod {
          egress = [ "10.12.14.181/tcp" ];
        }));
      msg = "podman egress must be <ipv4>:<port>/<proto>";
    }
    {
      ok = !(ok ((pod { }) // { internet = true; }));
      msg = "private podman with internet = true has no internet path: rejected";
    }
    {
      ok =
        !(ok (pod {
          index = 155;
        }));
      msg = "podman index stays 1-154";
    }
    {
      ok =
        !(ok {
          name = "gist";
          kind = "podman";
          internet = false;
          net.uses = [ "litellm.web" ];
        });
      msg = "uses without private = true is rejected for podman too";
    }
    {
      ok =
        privPods != [ ]
        && builtins.all (
          s: !s.internet && builtins.match "10\\.89\\.250\\.[0-9]+" s.net.ip != null
        ) privPods;
      msg = "inventory private podman services stay internet = false on 10.89.250.x";
    }
  ];
  bad = builtins.filter (c: !c.ok) checks;
in
if bad == [ ] then true else throw "podman-net: ${(builtins.head bad).msg}"
