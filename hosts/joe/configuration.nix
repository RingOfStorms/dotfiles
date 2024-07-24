{
  config,
  lib,
  pkgs,
  settings,
  ...
}@args:
{
  imports = [
    # Common components this machine uses
    (settings.hostsDir + "/_common/components/neovim.nix")
    (settings.hostsDir + "/_common/components/systemd_boot.nix")
    (settings.hostsDir + "/_common/components/ssh.nix")
    (settings.hostsDir + "/_common/components/caps_to_escape_in_tty.nix")
    (settings.hostsDir + "/_common/components/font_jetbrainsmono.nix")
    (settings.hostsDir + "/_common/components/audio.nix")
    (settings.hostsDir + "/_common/components/home_manager.nix")
    (settings.hostsDir + "/_common/components/gnome_xorg.nix")
    (settings.hostsDir + "/_common/components/docker.nix")
    (settings.hostsDir + "/_common/components/nebula.nix")
    # Users this machine has
    (settings.usersDir + "/root/configuration.nix")
    (settings.usersDir + "/josh/configuration.nix")
  ];

  # machine specific configuration
  # ==============================
  hardware.enableAllFirmware = true;
  # Connectivity
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  environment.shellAliases = {
    wifi = "nmtui";
  };

  environment.systemPackages = with pkgs; [ nvtopPackages.full ];

  # nvidia gfx https://nixos.wiki/wiki/Nvidia
  # =========
  # Enable OpenGL
  hardware.opengl = {
    enable = true;
    # driSupport = true;
    driSupport32Bit = true;
  };

  # Load nvidia driver for Xorg and Wayland
  virtualisation.docker.enableNvidia = true;
  virtualisation.docker = {
    extraOptions = "--experimental";
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    # Modesetting is required.
    modesetting.enable = true;

    # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
    # Enable this if you have graphical corruption issues or application crashes after waking
    # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead 
    # of just the bare essentials.
    powerManagement.enable = false;

    # Fine-grained power management. Turns off GPU when not in use.
    # Experimental and only works on modern Nvidia GPUs (Turing or newer).
    powerManagement.finegrained = false;

    # Use the NVidia open source kernel module (not to be confused with the
    # independent third-party "nouveau" open source driver).
    # Support is limited to the Turing and later architectures. Full list of 
    # supported GPUs is at: 
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus 
    # Only available from driver 515.43.04+
    # Currently alpha-quality/buggy, so false is currently the recommended setting.
    open = false;

    # Enable the Nvidia settings menu,
    # accessible via `nvidia-settings`.
    nvidiaSettings = true;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}
