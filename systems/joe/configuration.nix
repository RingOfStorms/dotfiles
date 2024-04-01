{ config, lib, pkgs, settings, ... } @ args:
{
  imports =
    [
      (settings.usersDir + "/root/configuration.nix")
      (settings.usersDir + "/josh/configuration.nix")
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "keep";
    };
    timeout = 5;
    efi = {
      canTouchEfiVariables = true;
    };
  };

  # We want connectivity
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;

  # Enable sound.
  sound.enable = true;
  hardware.pulseaudio.enable = true;
  hardware.pulseaudio.package = pkgs.pulseaudioFull;

  hardware.enableAllFirmware = true;

  # I want this globally even for root so doing it outside of home manager
  services.xserver.xkbOptions = "caps:escape";
  console = {
    earlySetup = true;
    packages = with pkgs; [ terminus_font ];
    # We want to be able to read the screen so use a 32 sized font...
    # font = "${pkgs.terminus_font}/share/consolefonts/ter-132n.psf.gz";
    useXkbConfig = true; # use xkb.options in tty. (caps -> escape)
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [
    22 # sshd
  ];
  # networking.firewall.allowedUDPPorts = [ ... ];

  fonts.packages = with pkgs; [
    (nerdfonts.override { fonts = [ "JetBrainsMono" ]; })
  ];

  services.xserver.enable = true;
  services.xserver.displayManager.gdm = {
    enable = true;
    autoSuspend = false;
    wayland = true;
  };
  services.xserver.desktopManager.gnome.enable = true;
  services.gnome.core-utilities.enable = false;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # extras, more for my neovim setup TODO move these into a more isolated place for nvim setup? Should be its own flake probably
    cargo
    rustc
    nodejs_21
    python313
    # ripgrep # now in common
    nodePackages.cspell
  ];

  # does for all shells. Can use `programs.zsh.shellAliases` for specific ones
  environment.shellAliases = {
    wifi = "nmtui";
  };


  # nvidia gfx
  # =========
  # Enable OpenGL
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];
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
