# Boot debugging aids for diagnosing the impermanence-in-initrd failure on
# o002 (Oracle Ampere aarch64). Two mechanisms:
#
# 1. Serial console output: force all kernel + initrd messages to the
#    Oracle serial console (ttyAMA0, the pl011 SBSA UART at 0x9000000)
#    AND tty1, so the OCI serial console shows exactly where boot hangs.
#
# 2. initrd SSH: bring up networking + sshd in the initrd so that if the
#    bcachefs-reset-root / mount path hangs BEFORE pivot, we can still SSH
#    into the initrd (port 22) to inspect and recover. Essential on a
#    headless cloud box with no physical console.
#
# Remove this module (and flip enableImpermanence) once impermanence boots
# reliably or is abandoned.
{ config, lib, pkgs, ... }:
{
  # ── 1. Serial console ──────────────────────────────────────────────────
  boot.kernelParams = [
    "console=ttyAMA0,115200"
    "console=tty1"
    # Verbose initrd so we see each service in the serial log.
    "systemd.log_level=debug"
    "systemd.log_target=console"
    "rd.systemd.show_status=true"
    "rd.udev.log_level=info"
  ];

  # ── 2. initrd SSH (systemd-initrd networking) ──────────────────────────
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 22;
      # Authorized key = the fleet nix2nix key (same one used for the
      # normal-boot root login).
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxNhtJNx/y4W54kAGmm2pF80l437z1RLWl/GTVKy0Pd josh@lio"
      ];
      # Dedicated initrd host key. Read at BUILD TIME from lio (the builder)
      # and embedded in the initrd. Generated once at
      # /tmp/o002-initrd/ssh_host_ed25519_key (debug-only; throwaway key).
      # NOTE: embeds a private key in the world-readable nix store — fine for
      # this short-lived debug cycle, remove with this module afterward.
      hostKeys = [ /tmp/o002-initrd/ssh_host_ed25519_key ];
    };
  };

  # Ensure initrd has the virtio NIC driver so networking comes up early.
  boot.initrd.availableKernelModules = [ "virtio_net" "virtio_pci" ];
}
