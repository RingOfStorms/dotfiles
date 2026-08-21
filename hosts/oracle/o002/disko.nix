# Disko partitioning + runtime mounts for o002 (Oracle Ampere aarch64).
#
# Pulls in disko's NixOS module and the shared bcachefs layout from the
# impermanence flake (flakes/impermanence/disko-bcachefs.nix), with
# cloud-box defaults: unencrypted (a headless cloud VM has no console/USB
# to enter a passphrase at boot), single /dev/sda, 8G swap, 3G ESP.
#
# enableConfig defaults to true: disko both partitions/formats at install
# time (via nixos-anywhere) AND emits the runtime `fileSystems` for the
# bcachefs subvolumes (@root -> /, @nix -> /nix, @persist -> /persist,
# @snapshots -> /.snapshots). No impermanence here, so disko owns mounts.
{ disko, impermanence, ... }:
{
  imports = [
    disko.nixosModules.disko
    (import "${impermanence}/disko-bcachefs.nix" {
      disk = "/dev/sda";
      swapSize = "8G";
      encrypted = false;
    })
  ];
}
