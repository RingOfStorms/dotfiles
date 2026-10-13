# The h002 bcachefs data pool (4× 12 TB IronWolf, replicas=2), mounted at /data.
# Gated by constants.dataPool.enable so the bench box and the first post-move
# boot never mount (or upgrade) the pool automatically.
{
  lib,
  pkgs,
  constants,
  ...
}:
let
  pool = constants.dataPool;
in
lib.mkMerge [
  {
    boot.supportedFilesystems = [ "bcachefs" ];
    environment.systemPackages = [
      pkgs.bcachefs-tools
      pkgs.smartmontools
    ];
    # Drive health: short test weekly, long test monthly, warn on attribute changes.
    services.smartd = {
      enable = true;
      autodetect = true;
      defaults.autodetected = "-a -o on -S on -s (S/../../7/03|L/../01/./04)";
    };
  }
  (lib.mkIf pool.enable {
    fileSystems."/data" = {
      device = "UUID=${pool.uuid}";
      fsType = "bcachefs";
      options = [
        "defaults"
        "x-systemd.device-timeout=600s"
        "nofail"
      ];
    };
  })
]
