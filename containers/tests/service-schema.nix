let
  lib = import ../lib.nix;
  rejects = value: !(builtins.tryEval (builtins.deepSeq (lib.normalize value) true)).success;
  login = lib.edgeLoginServices ../.;
  names = map (s: s.service) login;
  services = lib.allServices ../.;
in
assert rejects { name = "legacy"; nginx = "server {}"; };
assert rejects { name = "bad"; secrets = [ "../secret" ]; };
assert (lib.normalize { name = "ok"; secrets = [ "litellm-env" ]; }).secrets == [ "litellm-env" ];
assert builtins.all (n: builtins.elem n names) [ "arr" "immich" "vaultwarden" ];
assert builtins.all (s: !(s ? nginx)) services;
assert builtins.all (s: s.secrets != [ ]) (builtins.filter (s: builtins.elem s.name [ "arr" "life" "litellm" "open-webui" "vaultwarden" ]) services);
true
