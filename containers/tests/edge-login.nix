let
  lib = import ../lib.nix;
  pattern = builtins.replaceStrings [ "<HOST>" "\\[\\]" ] [ "[0-9.]+" "[[]]" ] (lib.edgeLogin.failregex [ "vault.example.com" "photos.example.com" "jellyfin.example.com" ]);
  matches = line: builtins.match pattern line != null;
in
assert builtins.all (status: matches ''1.2.3.4 vault.example.com [] "POST /identity/connect/token HTTP/1.1" ${status}'') [ "400" "401" "403" "429" ];
assert matches ''1.2.3.4 photos.example.com [] "POST /api/auth/login HTTP/1.1" 401'';
assert matches ''1.2.3.4 jellyfin.example.com [] "POST /Users/AuthenticateByName HTTP/1.1" 403'';
assert !(matches ''1.2.3.4 vault.example.com [] "POST /identity/connect/token HTTP/1.1" 200'');
assert !(matches ''1.2.3.4 other.example.com [] "POST /login HTTP/1.1" 401'');
assert lib.edgeLogin.zone == "fleet_edge_login";
true
