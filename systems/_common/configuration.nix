{ config, lib, pkgs, settings, ... }:
let
  home-manager = builtins.fetchTarball {
    url = "https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz";
    # to get hash run `nix-prefetch-url --unpack "https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz"`
    sha256 = "0562y8awclss9k4wk3l4akw0bymns14sfy2q9n23j27m68ywpdkh";
  };
in
{
  imports =
    [
      # Include the results of the hardware scan.
      # Note we need to be in the /etc/nixos directory with this entire config repo for this relative path to work
      ../../hardware-configuration.nix
      # home manager import
      (import "${home-manager}/nixos")
    ];

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Home manager options
  security.polkit.enable = true;
  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = { inherit settings; };

  # ==========
  #   Common
  # ==========
  networking.hostName = settings.system.hostname;
  time.timeZone = settings.system.timeZone;

  # Select internationalisation properties.
  i18n.defaultLocale = settings.system.defaultLocale;
  i18n.extraLocaleSettings = {
    LC_ADDRESS = settings.system.defaultLocale;
    LC_IDENTIFICATION = settings.system.defaultLocale;
    LC_MEASUREMENT = settings.system.defaultLocale;
    LC_MONETARY = settings.system.defaultLocale;
    LC_NAME = settings.system.defaultLocale;
    LC_NUMERIC = settings.system.defaultLocale;
    LC_PAPER = settings.system.defaultLocale;
    LC_TELEPHONE = settings.system.defaultLocale;
    LC_TIME = settings.system.defaultLocale;
  };

  system.stateVersion = "23.11";
}
