let
  lib = import ../lib.nix;
  rejects = value: !(builtins.tryEval (builtins.deepSeq (lib.normalize value) true)).success;
  login = lib.edgeLoginServices ../.;
  names = map (s: s.service) login;
  services = lib.allServices ../.;
  minecraft = lib.normalize (import ../minecraft/service.nix);
in
assert rejects { name = "legacy"; nginx = "server {}"; };
assert rejects { name = "bad"; secrets = [ "../secret" ]; };
assert (lib.normalize { name = "ok"; secrets = [ "litellm-env" ]; }).secrets == [ "litellm-env" ];
assert builtins.all (n: builtins.elem n names) [ "arr" "immich" "vaultwarden" ];
assert builtins.all (s: !(s ? nginx)) services;
assert builtins.all (s: s.secrets != [ ]) (builtins.filter (s: builtins.elem s.name [ "arr" "life" "litellm" "open-webui" "vaultwarden" ]) services);
assert minecraft.net.private && minecraft.net.ip == "10.233.18.2";
assert minecraft.routes.game.proto == "tcp" && minecraft.routes.game.port == 25565;
assert minecraft.routes.game.via == [ "router" ];
assert minecraft.routes.web.via == [ "edge" ];
true
