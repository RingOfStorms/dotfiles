{ config, lib, pkgs, settings, ... } @ args:
let
  homeManagerUser = import "${settings.usersDir}/${settings.user.username}/home.nix";
in
{
  imports =
    [
      # Our custom stuff
      ./stupid-keyboard.nix
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

  # TODO evaluate if any of this kernal/hardware sutff is actually needed for our pocket. This is a hodge podge of shit from online
  # The GPD Pocket3 uses a tablet OLED display, that is mounted rotated 90° counter-clockwise.
  # This requires cusotm kernal params.
  boot.kernelParams = [
    "video=DSI-1:panel_orientation=right_side_up"
    "fbcon=rotate:1"
    "mem_sleep_default=s2idel"
  ];
  boot.kernelModules = [ "btusb" ];
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "usbhid" "thunderbolt" ];
  services.xserver.videoDrivers = [ "intel" ];
  hardware.opengl = {
    enable = true;
    driSupport = true;
  };
  hardware.opengl.extraPackages = with pkgs; [
    intel-media-driver
    intel-vaapi-driver
  ];
  hardware.enableAllFirmware = true;

  # [Laptop] screens with brightness settings
  programs.light.enable = true;

  # I want this globally even for root so doing it outside of home manager
  services.xserver.xkbOptions = "caps:escape";
  console = {
    earlySetup = true;
    packages = with pkgs; [ terminus_font ];
    # We want to be able to read the screen so use a 32 sized font...
    font = "${pkgs.terminus_font}/share/consolefonts/ter-132n.psf.gz";
    useXkbConfig = true; # use xkb.options in tty. (caps -> escape)
  };

  # Attempting to get fingerprint scanner to work... having issues though
  #services.fwupd.enable = true;
  #services.fprintd = {
  #  enable = true;
  #  package = pkgs.fprintd-tod;
  #  tod.enable = true;
  #  tod.driver = pkgs.libfprint-2-tod1-vfs0090;
  #  #tod.driver = pkgs.libfprint-2-tod1-goodix;
  #};

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

  users.users.root.initialPassword = "password1";
  users.users.${settings.user.username} = {
    initialPassword = "password1";
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "input" ];
    shell = pkgs.zsh;
  };
  # TODO how to do this from home manager file instead
  environment.pathsToLink = [ "/share/fish" ];
  home-manager.users.${settings.user.username} = homeManagerUser;

  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
  services.gnome.core-utilities.enable = false;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # Basics
    neovim
    vim
    wget
    curl
    neofetch
    bat
    htop
    nvtop
    unzip
    git
    # [Laptop] Battery status
    acpi
    # extras, more for my neovim setup TODO move these into a more isolated place for nvim setup? Should be its own flake probably
    cargo
    rustc
    nodejs_21
    python313
    ripgrep
    nodePackages.cspell
    #
    fzf
  ];

  programs.zsh = {
    enable = true;
  };

  # does for all shells. Can use `programs.zsh.shellAliases` for specific ones
  environment.shellAliases = {
    n = "nvim";
    battery = "acpi";
    wifi = "nmtui";
    bat = "bat --theme Coldark-Dark";
    cat = "bat --pager=never -p";
    nix-boot-clean = "find '/boot/loader/entries' -type f | head -n -4 | xargs -I {} rm {}; nix-collect-garbage -d; nixos-rebuild boot; echo; df";
  };
}
