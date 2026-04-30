{
  pkgs,
  constants,
  ...
}:
let
  nixServe = constants.services.nixServe;
in
{
  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # System76
  hardware.system76.enableAll = true;

  # Hardware watchdog for freeze detection and recovery
  boot.kernelParams = [ "nmi_watchdog=1" ];
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";      # Reboot if system hangs for 30 seconds
    RebootWatchdogSec = "10m";       # Timeout for reboot to complete
    KExecWatchdogSec = "10m";        # Timeout for kexec to complete
  };

  # ── Meshtastic / serial device access ──────────────────────────────────────
  # CH340/CH341 USB-to-serial (used by ThinkNode M5, many ESP32 boards, etc.)
  # TAG+="uaccess" grants access to the logged-in seat user (needed for
  # Chrome Web Serial flashers). GROUP="dialout" is the fallback for non-seat
  # access (SSH, scripts, etc.).
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", GROUP="dialout", MODE="0660", TAG+="uaccess"
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4", GROUP="dialout", MODE="0660", TAG+="uaccess"
  '';

  services = {
    # https://discourse.nixos.org/t/very-high-fan-noises-on-nixos-using-a-system76-thelio/23875/10
    # Fixes insane jet speed fan noise
    power-profiles-daemon.enable = false;
    tlp = {
      enable = true;
      # settings = {
      #   CPU_BOOST_ON_AC = 1;
      #   CPU_BOOST_ON_BAT = 0;
      #   CPU_SCALING_GOVERNOR_ON_AC = "performance";
      #   CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      #   STOP_CHARGE_THRESH_BAT0 = 95;
      # };
    };

    # Binary cache server (drop-in nix-serve replacement)
    nix-serve = {
      enable = true;
      package = pkgs.nix-serve-ng;
      port = nixServe.port;
      # openFirewall = true;
      secretKeyFile = nixServe.secretKeyFile;
    };
  };

  # Also allow this key to work for root user, this will let us use this as a remote builder easier
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15"
  ];
  nix.distributedBuilds = true;
  # Allow emulation of aarch64-linux binaries for cross compiling
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  environment.systemPackages = with pkgs; [
    lua
    qdirstat
    ffmpeg-full
    appimage-run
    nodejs_24
    foot
    vlc
    firefox
    (google-chrome.override {
      commandLineArgs = [
        "--remote-debugging-port=9222"
        "--remote-allow-origins=*"
      ];
    })
  ];
}
