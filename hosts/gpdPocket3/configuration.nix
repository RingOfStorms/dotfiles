{ config, lib, pkgs, settings, ... } @ args:
{
  imports =
    [
      # TODO revisit
      (settings.hostsDir + "/_common/components/todo_neovim.nix")
      # Common components this machine uses
      (settings.hostsDir + "/_common/components/systemd_boot.nix")
      (settings.hostsDir + "/_common/components/ssh.nix")
      (settings.hostsDir + "/_common/components/caps_to_escape_in_tty.nix")
      (settings.hostsDir + "/_common/components/font_jetbrainsmono.nix")
      (settings.hostsDir + "/_common/components/home_manager.nix")
      (settings.hostsDir + "/_common/components/gnome_wayland.nix")
      # Users this machine has
      (settings.usersDir + "/root/configuration.nix")
      (settings.usersDir + "/josh/configuration.nix")
      # Our custom stuff
      ./stupid-keyboard.nix
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
  # Enable sound.
  sound.enable = true;
  hardware.pulseaudio.enable = true;
  hardware.pulseaudio.package = pkgs.pulseaudioFull;

  environment.systemPackages = with pkgs; [
    # [Laptop] Battery status
    acpi
  ];
  environment.shellAliases = {
    battery = "acpi";
  };
  # [Laptop] screens with brightness settings
  programs.light.enable = true;

  console = {
    # We want to be able to read the screen so use a 32 sized font on this tiny panel
    font = "${pkgs.terminus_font}/share/consolefonts/ter-132n.psf.gz";
  };

  # ========

  # FINGERPRINTS for the sensor on GPD P3 do not work on linux yet: todo find the source of this again online for tracking...
  # Attempting to get fingerprint scanner to work... having issues though, no device detected with all methods
  # services.fprintd = {
  #   enable = true;
  #   tod = {
  #     enable = true;
  #     driver = pkgs.libfprint-2-tod1-elan;
  #   };
  # };

  # TODO evaluate if any of this kernal/hardware stuff is actually needed for our pocket. This is a hodge podge of shit from online
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
  # Stuff from https://github.com/NixOS/nixos-hardware/blob/9a763a7acc4cfbb8603bb0231fec3eda864f81c0/gpd/pocket-3/default.nix
  services.fstrim.enable = true;
  services.xserver.libinput.enable = true;
  services.tlp.enable = lib.mkDefault ((lib.versionOlder (lib.versions.majorMinor lib.version) "21.05")
    || !config.services.power-profiles-daemon.enable);
}
