{
  pkgs,
  lib,
  constants,
  ...
}:
let
  nixServe = constants.services.nixServe;
in
{
  # Close port 22 on the global allow-list set by hardening.nix and re-open
  # it only on tailscale0 + the LAN CIDR. Using nftables source-address
  # filtering (rather than per-interface) means it keeps working regardless
  # of whether the LAN is reached via wired or Wi-Fi.
  #
  # `allowedTCPPorts` has list-merge semantics across modules, and `mkForce`
  # replaces *all* contributions — so any port this host should open
  # globally must be re-listed here (currently none).
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 22 ];
  networking.firewall.extraInputRules = ''
    ip saddr 10.12.14.0/24 tcp dport 22 accept
  '';

  # No root SSH on lio (overrides the shared hardening module).
  services.openssh.settings.PermitRootLogin = lib.mkForce "no";

  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # System76
  hardware.system76.enableAll = true;

  # Memory: compressed RAM swap first, small disk swapfile (hardware-configuration.nix) as overflow.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };
  boot.kernel.sysctl = {
    # zram is cheap to swap to; tuned per the Fedora/Pop!_OS zram defaults
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    # Start writeback at 256MiB dirty, throttle writers at 1GiB
    "vm.dirty_background_bytes" = 268435456;
    "vm.dirty_bytes" = 1073741824;
  };
  # MGLRU thrashing protection: keep the last 1s of working set resident
  systemd.tmpfiles.rules = [ "w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000" ];
  systemd.oomd = {
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
  };

  # Deduplicate the store on a timer instead of inline during every build
  nix.settings.auto-optimise-store = lib.mkForce false;
  nix.optimise.automatic = true;

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
    # system76-power (via hardware.system76.enableAll) manages power profiles;
    # it conflicts with power-profiles-daemon. The earlier jet-engine fan fix
    # (https://discourse.nixos.org/t/very-high-fan-noises-on-nixos-using-a-system76-thelio/23875/10)
    # used TLP; if fans get loud, run `system76-power profile balanced`.
    power-profiles-daemon.enable = false;

    # Binary cache server (drop-in nix-serve replacement)
    nix-serve = {
      enable = true;
      package = pkgs.nix-serve-ng;
      port = nixServe.port;
      # openFirewall = true;
      secretKeyFile = nixServe.secretKeyFile;
    };
  };

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
    mpv
    firefox
    google-chrome
  ];
}
