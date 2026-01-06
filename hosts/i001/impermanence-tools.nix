{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.impermanence.tools;

  persistence = config.environment.persistence or { };

  normalizePath = v:
    if builtins.isString v then
      v
    else if v ? dirPath then
      v.dirPath
    else if v ? filePath then
      v.filePath
    else
      null;

  pathsFromList = f: xs: lib.filter (p: p != null) (map f xs);

  userPersistencePaths = users:
    lib.flatten (
      lib.mapAttrsToList (
        userName: userCfg:
        let
          home = (config.users.users.${userName} or { }).home or "/home/${userName}";
          normalizeUserPath = v:
            if builtins.isString v then
              if lib.hasPrefix "/" v then v else "${home}/${v}"
            else
              normalizePath v;
        in
        (pathsFromList normalizeUserPath (userCfg.directories or [ ]))
        ++ (pathsFromList normalizeUserPath (userCfg.files or [ ]))
      ) users
    );

  ignorePaths =
    lib.unique (
      lib.filter (p: p != null && p != "" && p != "/") (
        lib.flatten (
          lib.mapAttrsToList (
            persistRoot: persistCfg:
            [ persistRoot ]
            ++ (pathsFromList normalizePath (persistCfg.directories or [ ]))
            ++ (pathsFromList normalizePath (persistCfg.files or [ ]))
            ++ (userPersistencePaths (persistCfg.users or { }))
          ) persistence
        )
      )
    );

  ignoreFile = pkgs.writeText "bcache-impermanence-ignore-paths" (
    lib.concatStringsSep "\n" ignorePaths + "\n"
  );

  scriptFile = pkgs.writeText "bcache-impermanence.sh" (
    builtins.readFile ./impermanence-tools.sh
  );

  bcacheImpermanenceBin = pkgs.writeShellScriptBin "bcache-impermanence" ''
    export BCACHE_IMPERMANENCE_IGNORE_FILE="${ignoreFile}"
    exec ${pkgs.bash}/bin/bash "${scriptFile}" "$@"
  '';
in
{
  options.impermanence.tools = {
    # enable = lib.mkEnableOption "bcachefs impermanence tools (GC + CLI)";

    snapshotRoot = lib.mkOption {
      type = lib.types.str;
      default = "/.snapshots/old_roots";
      description = "Root directory containing old root snapshots.";
    };

    gc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable garbage collection of old root snapshots.";
      };

      keepPerMonth = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Keep at least this many snapshots per calendar month (latest ones).";
      };

      keepRecentWeeks = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Keep at least one snapshot per ISO week within this many recent weeks.";
      };

      keepRecentCount = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Always keep at least this many most recent snapshots overall.";
      };
    };
  };

  config = {
    # config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      bcacheImpermanenceBin
      pkgs.coreutils
      pkgs.findutils
      pkgs.diffutils
      pkgs.bcachefs-tools
      pkgs.fzf
    ];

    systemd.services."bcache-impermanence-gc" = lib.mkIf cfg.gc.enable {
      description = "Garbage collect bcachefs impermanence snapshots";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        exec ${bcacheImpermanenceBin}/bin/bcache-impermanence gc \
          --snapshot-root ${cfg.snapshotRoot} \
          --keep-per-month ${toString cfg.gc.keepPerMonth} \
          --keep-recent-weeks ${toString cfg.gc.keepRecentWeeks} \
          --keep-recent-count ${toString cfg.gc.keepRecentCount}
      '';
    };
  };
}
