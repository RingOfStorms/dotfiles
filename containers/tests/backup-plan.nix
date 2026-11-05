# Eval test for the backup target allow-list (BACKUP-PLAN.md §2.8, P1).
# Run from the repo root:
#   nix eval --impure --expr 'import ./containers/tests/backup-plan.nix'
# Returns true, or throws on the first failed check.
let
  lib = import ../lib.nix;
  hosts = (import ../../hosts/fleet.nix).hosts;
  t = lib.backupTargetIps {
    inherit hosts;
    self = "h004";
  };
  withJoe = lib.backupTargetIps {
    inherit hosts;
    self = "h004";
    lowTrustClients = [ "joe" ];
  };
  ssh = lib.firewallHighTrustIps {
    inherit hosts;
    exclude = [ "o002" "h004" ];
  };
  ssh6 = lib.firewallHighTrustIps6 {
    inherit hosts;
    exclude = [ "o002" "h004" ];
  };
  lowIps = builtins.filter (ip: ip != null) (
    map (h: if (h.trust or null) == "low" then h.overlayIp or null else null) (builtins.attrValues hosts)
  );
  module = builtins.readFile ../../flakes/fleet-agent/backup/target.nix;
  has = s: builtins.match ".*${s}.*" module != null;
in
assert t.ips != [ ] && t.ips6 != [ ];
assert builtins.elem hosts.lio.overlayIp t.ips;
assert builtins.elem hosts.lio.overlayIp6 t.ips6;
assert !(builtins.elem hosts.h004.overlayIp t.ips);
assert !(builtins.elem hosts.o002.overlayIp t.ips);
assert t.ips == ssh && t.ips6 == ssh6;
assert builtins.all (ip: !(builtins.elem ip t.ips)) lowIps;
assert withJoe.ips == ssh ++ [ hosts.joe.overlayIp ];
assert withJoe.ips6 == ssh6 ++ [ hosts.joe.overlayIp6 ];
# rest-server must be append-only with private repos, and the target root
# never holds a B2 credential (pusher tier only).
assert has "appendOnly = true;";
assert has "privateRepos = true;";
assert has "createHome = lib.mkForce false;";
assert !(has "restic_b2_");
true
