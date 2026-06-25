# initrd SSH recovery for o002 (Oracle Ampere aarch64, impermanence host).
#
# o002 runs bcachefs + impermanence with a boot-time root reset in initrd.
# If that ever hangs on this headless cloud box, initrd SSH is the only way
# in. We keep it as a permanent recovery aid:
#
#   - Serial console output to ttyAMA0 (Oracle's UART) so the OCI serial
#     console shows boot messages.
#   - sshd in the initrd (port 22) authorized with the fleet keys, using a
#     persistent host key at /persist/initrd/ssh_host_ed25519_key (survives
#     the root wipe; read at activation time on the target).
#
# To reach the initrd if a boot hangs:
#   ssh -i <nix2nix-or-personal-key> root@<o002-ip>
# (you'll land in the initrd shell environment before pivot).
{ config, lib, pkgs, ... }:
{
  # Serial console on the Oracle UART (kernel auto-detects via ACPI SPCR,
  # but make it explicit so initrd + early boot definitely log there).
  boot.kernelParams = [
    "console=ttyAMA0,115200"
    "console=tty1"
  ];

  # initrd SSH (systemd-initrd networking) for recovery.
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 22;
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxNhtJNx/y4W54kAGmm2pF80l437z1RLWl/GTVKy0Pd josh@lio"
      ];
      # Persistent initrd host key (survives the impermanence root wipe).
      # Read at activation time on the target; generate once with:
      #   ssh-keygen -t ed25519 -N "" -f /persist/initrd/ssh_host_ed25519_key
      hostKeys = [ "/persist/initrd/ssh_host_ed25519_key" ];
    };
  };

  # Ensure the virtio NIC driver is in initrd so networking comes up early.
  boot.initrd.availableKernelModules = [ "virtio_net" "virtio_pci" ];
}
