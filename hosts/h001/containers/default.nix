{
  constants,
  ...
}:
{
  imports = [
    ./dawarich.nix
    ./forgejo.nix
    ./immich.nix
    ./life.nix
    ./matrix.nix
    ./paperless.nix
    ./zitadel.nix
  ];

  config = {
    ## Give internet access
    networking = {
      nat = {
        enable = true;
        internalInterfaces = [ "ve-*" ];
        externalInterface = "enp0s31f6";
        enableIPv6 = true;
      };
      firewall.trustedInterfaces = [ "ve-*" ];
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
