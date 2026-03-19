# Service constants for h002 (NAS - bcachefs)
# Single source of truth for ports, UIDs/GIDs, data paths.
{
  host = {
    name = "h002";
    overlayIp = "100.64.0.3";
    lanIp = "10.12.14.183";
    primaryUser = "luser";
    stateVersion = "25.11";
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
