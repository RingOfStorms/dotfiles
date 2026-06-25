# Disko partitioning for an Oracle Ampere (aarch64) cloud VM.
#
# Pulls in disko's NixOS module and the shared bcachefs layout from the
# impermanence flake (flakes/impermanence/disko-bcachefs.nix), with
# cloud-box defaults: unencrypted (a headless cloud VM has no console/USB
# to enter a passphrase at boot), single /dev/sda, 8G swap, 3G ESP.
#
# Partition-only mode: `disko.enableConfig = false` makes disko partition
# and format at install time (via nixos-anywhere) WITHOUT emitting runtime
# `fileSystems`. The bcachefs-impermanence module owns the runtime mounts,
# so this avoids a double-definition of fileSystems."/" etc.
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

  disko.enableConfig = false;
}
