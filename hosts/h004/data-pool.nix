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

    # Old 750 GB Seagate hybrid (ST750LX003, ~84k power-on hours) on the Vantec
    # card: standalone unencrypted bcachefs for throwaway data only. Not part of
    # the pool; reformatted from an old pool member so it no longer carries the
    # pool UUID. nofail so a dead drive doesn't block boot.
    fileSystems."/scratch" = {
      device = "UUID=4cf7d03f-7c1f-44a4-8c34-fe87f7a3d9c3";
      fsType = "bcachefs";
      options = [
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
  }
  (lib.mkIf pool.enable {
    fileSystems."/data" = {
      device = "UUID=${pool.uuid}";
      fsType = "bcachefs";
      options = [
        "defaults"
        "x-systemd.device-timeout=600s"
        # A first mount after a bcachefs version bump runs an upgrade/check
        # (about 3 min for this pool on 1.38 -> 1.39); allow up to 30.
        "x-systemd.mount-timeout=30min"
        "nofail"
      ];
    };
  })
]
