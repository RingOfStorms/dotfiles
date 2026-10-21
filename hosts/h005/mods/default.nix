{ ... }:
{
  imports = [
    ./networking.nix
    ./adguardhome.nix
    ./ddns.nix
    ../router-forwards.nix
    ./ups.nix
    ./speedtest.nix
  ];
}
