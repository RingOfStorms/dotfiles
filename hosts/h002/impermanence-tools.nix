{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.impermanence.tools;

  bcacheImpermanenceBin = pkgs.writeShellScriptBin "bcache-impermanence" (
    builtins.readFile ./impermanence-tools.sh
  );

in
{
  options.impermanence.tools = {
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
