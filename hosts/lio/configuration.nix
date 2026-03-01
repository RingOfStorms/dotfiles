{
  pkgs,
  constants,
  ...
}:
let
  nixServe = constants.services.nixServe;
in
{
  system.stateVersion = "23.11";

  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # System76
  hardware.system76.enableAll = true;

  # Hardware watchdog for freeze detection and recovery
  boot.kernelParams = [ "nmi_watchdog=1" ];
  systemd.watchdog = {
    runtimeTime = "30s";      # Reboot if system hangs for 30 seconds
    rebootTime = "10m";       # Timeout for reboot to complete
    kexecTime = "10m";        # Timeout for kexec to complete
  };

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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJN2nsLmAlF6zj5dEBkNSJaqcCya+aB6I0imY8Q5Ew0S nix2lio"
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
    (google-chrome.override {
      commandLineArgs = [
        "--remote-debugging-port=9222"
        "--remote-allow-origins=*"
      ];
    })
  ];
}
