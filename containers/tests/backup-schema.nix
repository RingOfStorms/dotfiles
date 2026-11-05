# Eval test for the service.nix backup schema and checkBackupPaths
# (BACKUP-PLAN.md §3.1, §3.3, P3).
#   nix eval --impure --expr 'import ./containers/tests/backup-schema.nix'
let
  lib = import ../lib.nix;
  subj = import ../backup-subjects.nix;
  rejects = x: !(builtins.tryEval (builtins.deepSeq x x)).success;
  base = {
    name = "t";
    kind = "nixos";
    persist.data = "/var/lib/t";
    requires = [ "wd10" ];
  };
  b = backup: (lib.normalize (base // { inherit backup; })).backup;
  ep = e: b { extraPaths = [ ({ requires = "wd10"; } // e) ]; };
  svcs = lib.allServices ../.;
  names = map (s: s.name) svcs;
  mk =
    name: paths:
    lib.normalize (
      base
      // {
        inherit name;
        backup.extraPaths = map (p: {
          path = p;
          requires = "wd10";
        }) paths;
      }
    );
in
# defaults
assert (lib.normalize base).backup.enable;
assert (lib.normalize base).backup.hooks.pre == null;
assert (b { hooks.pre = "true"; }).hooks.pre == "true";
assert (b { enable = false; }).enable == false;
# rejects
assert rejects (lib.normalize (base // { backupHook = "x"; }));
assert rejects (b {
  bogus = 1;
});
assert rejects (b {
  hooks.during = "x";
});
assert rejects (b {
  hooks.pre = "";
});
assert rejects (b {
  exclude = [ "/abs" ];
});
assert rejects (b {
  exclude = [ "a/../b" ];
});
assert rejects (b {
  enable = false;
  exclude = [ "x" ];
});
assert rejects (ep {
  path = "relative";
});
assert rejects (ep {
  path = "/drives/wd10/../etc";
});
assert rejects (ep {
  path = "/srv/containers/x";
});
assert rejects (ep {
  path = "/etc/x";
});
assert rejects (ep {
  path = "/var/lib/secrets_manager_hydrated/x";
});
assert rejects (ep {
  path = "/drives/x";
  requires = "nvidia";
});
assert rejects (ep {
  path = "/drives/wd10/x";
  mount = "/drives/other";
});
assert rejects (ep {
  path = "/drives/wd10/x";
  mount = "/drives/wd10";
  sentinel = "/elsewhere/s";
});
assert rejects (ep {
  path = "/drives/wd10/x";
  onMove = "copy";
});
assert rejects (ep {
  path = "/drives/wd10/x";
  extra = 1;
});
assert
  (ep {
    path = "/drives/wd10/x";
    mount = "/drives/wd10";
    sentinel = "/drives/wd10/.mounted";
    exclude = [ "cache" ];
  }).extraPaths == [
    {
      path = "/drives/wd10/x";
      mount = "/drives/wd10";
      sentinel = "/drives/wd10/.mounted";
      onMove = "restore";
      requires = "wd10";
      exclude = [ "cache" ];
    }
  ];
# checkBackupPaths
assert
  lib.checkBackupPaths {
    services = [
      (mk "a" [ "/drives/wd10/a" ])
      (mk "b" [ "/drives/wd10/b" ])
    ];
  } != [ ];
assert rejects (
  lib.checkBackupPaths {
    services = [
      (mk "a" [ "/drives/wd10/a" ])
      (mk "b" [ "/drives/wd10/a/sub" ])
    ];
  }
);
assert rejects (
  lib.checkBackupPaths {
    services = [
      (mk "a" [
        "/drives/wd10/a"
        "/drives/wd10/a"
      ])
    ];
  }
);
assert rejects (
  lib.checkBackupPaths {
    services = [ (mk "a" [ "/drives/wd10" ]) ];
    hostSubjects.media = [ "/drives/wd10/media" ];
  }
);
# prefix of a name is not a parent path
assert
  lib.checkBackupPaths {
    services = [ (mk "a" [ "/drives/wd10/a" ]) ];
    hostSubjects.m = [ "/drives/wd10/ab" ];
  } != [ ];
# the real tree: hooks migrated, excludes moved, every subject has a key
assert builtins.all (s: !(s ? backupHook)) svcs;
assert (builtins.head (builtins.filter (s: s.name == "forgejo") svcs)).backup.hooks.pre != null;
assert
  (builtins.head (builtins.filter (s: s.name == "immich") svcs)).backup.exclude == [ "mlcache" ];
assert
  builtins.sort builtins.lessThan (builtins.attrNames subj.hosts)
  == builtins.sort builtins.lessThan (builtins.filter (n: n != "localai") names);
assert builtins.all (k: builtins.any (a: a.value == subj.subs.h004) subj.registry.${k}.access) (
  builtins.attrNames subj.registry
);
# placement-exact grants: each subject has at most one client host
assert builtins.all (n: builtins.length subj.hosts.${n} <= 1) (builtins.attrNames subj.hosts);
true
