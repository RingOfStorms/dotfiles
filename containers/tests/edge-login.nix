let
  lib = import ../lib.nix;
  pattern = builtins.replaceStrings [ "<HOST>" "\\[\\]" ] [ "[0-9.]+" "[[]]" ] (lib.edgeLogin.failregex [ "vault.example.com" "photos.example.com" "jellyfin.example.com" ]);
  matches = line: builtins.match pattern line != null;
  services = lib.edgeLoginServices ../.;
  stubLib = {
    all = builtins.all;
    mkBefore = x: x;
    mkOption = x: x;
    mapAttrs = builtins.mapAttrs;
    filterAttrs = pred: attrs: builtins.listToAttrs (map (n: { name = n; value = attrs.${n}; }) (builtins.filter (n: pred n attrs.${n}) (builtins.attrNames attrs)));
    unique = x: x;
    concatLists = builtins.concatLists;
    mapAttrsToList = f: attrs: map (n: f n attrs.${n}) (builtins.attrNames attrs);
    types = { package = null; nullOr = x: x; str = null; };
  };
  config = {
    fleet = { edgeVhost = { package = "fleet-edge"; }; wildcardCertDir = "/cert"; };
    services.nginx = { user = "nginx"; group = "nginx"; virtualHosts = {}; };
  };
  receiver = import ../../hosts/_shared_assets/utilities/edge-vhost-receiver.nix {
    inherit config;
    lib = stubLib;
    pkgs.systemd = "/systemd";
    fleet = { global.domain = "example.com"; hosts = {}; };
  };
  edge = import ../../hosts/oracle/o002/nginx.nix {
    inherit config;
    lib = stubLib;
    pkgs.systemd = "/systemd";
    constants = {};
    fleet = { global.domain = "joshuabell.xyz"; hosts.h005.overlayIp = "100.64.0.3"; };
  };
in
assert builtins.all (status: matches ''1.2.3.4 vault.example.com [] "POST /identity/connect/token HTTP/1.1" ${status}'') [ "400" "401" "403" "429" ];
assert matches ''1.2.3.4 photos.example.com [] "POST /api/auth/login HTTP/1.1" 401'';
assert matches ''1.2.3.4 jellyfin.example.com [] "POST /Users/AuthenticateByName HTTP/1.1" 403'';
assert !(matches ''1.2.3.4 vault.example.com [] "POST /identity/connect/token HTTP/1.1" 200'');
assert !(matches ''1.2.3.4 other.example.com [] "POST /login HTTP/1.1" 401'');
assert lib.edgeLogin.zone == "fleet_edge_login";
assert map (s: s.service) services == [ "arr" "immich" "vaultwarden" ];
assert (builtins.head services).fqdns == [ "jellyfin.joshuabell.xyz" ];
assert builtins.elem "f ${lib.edgeLogin.log} 0640 nginx nginx -" receiver.config.systemd.tmpfiles.rules;
assert receiver.config.systemd.services.nginx.serviceConfig.ExecStartPre == [ "+/systemd/bin/systemd-tmpfiles --create --prefix=${lib.edgeLogin.log}" ];
assert edge.services.fail2ban.jails.fleet-login-arr.settings.backend == "polling";
assert edge.systemd.services.fail2ban.serviceConfig.ExecStartPre == receiver.config.systemd.services.nginx.serviceConfig.ExecStartPre;
true
