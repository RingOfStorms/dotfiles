# Service constants for h004 (h002 NAS rebuild: new board, bcachefs root + impermanence)
# Single source of truth for ports, UIDs/GIDs, data paths.
{
  host = {
    name = "h004";
    # Filled in after the bench box joins the tailnet (`tailscale ip -4`).
    # Beszel stays off until this is set.
    overlayIp = null;
    # Bench DHCP address until cutover; then h003 needs a static lease for the
    # new board's MAC (see readme.md).
    lanIp = null;
    primaryUser = "luser";
    stateVersion = "26.05";
  };

  # The 4× IronWolf bcachefs pool from h002. Leave false on the bench and for
  # the first boot after the drives move: no /data mount and no NFS server,
  # so nothing touches the pool until it has been checked by hand (readme.md,
  # "Cutover"). Flip to true only after the read-only compatibility mount
  # succeeds.
  dataPool = {
    enable = false;
    uuid = "53a26b95-941b-4f41-b049-c166905ed8c2";
  };

  services = {
    nfs = {
      nfsPort = 2049;
      rpcbindPort = 111;
      mountdPort = 892;
      lockdPort = 32803;
      statdPort = 662;
      exportRoot = "/data";
    };

    pinchflat = {
      uid = 186;
      gid = 186;
      mediaDir = "/data/pinchflat/media";
    };

    nixarr = {
      mediaDir = "/data/nixarr/media";
    };
  };
}
