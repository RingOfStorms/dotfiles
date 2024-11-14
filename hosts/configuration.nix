{
  settings,
  config,
  ...
}:
let
  defaultLocal = "en_US.UTF-8";
in
{
  imports = [
    # Secrets management
    ./ragenix.nix
    # Include the results of the hardware scan.
    (/${settings.hostsDir}/${settings.system.hostname}/hardware-configuration.nix)
    # Include the specific machine's config.
    (/${settings.hostsDir}/${settings.system.hostname}/configuration.nix)
  ];

  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # allow mounting ntfs filesystems
  boot.supportedFilesystems = [ "ntfs" ];

  # Fallback quickly if substituters are not available.
  nix.settings.connect-timeout = 5;
  nix.settings.download-attempts = 3;
  # The default at 10 is rarely enough.
  nix.settings.log-lines = 50;
  # Avoid disk full issues
  nix.settings.max-free = (3000 * 1024 * 1024);
  nix.settings.min-free = (1000 * 1024 * 1024);
  # Avoid copying unnecessary stuff over SSH
  nix.settings.builders-use-substitutes = true;
  # Slower but mroe robust during crash TODO enable once we upgrade nix
  # nix.settings.fsync-store-paths = true;
  # nix.settings.fsync-metadata = true;
  nix.settings.auto-optimise-store = true;

  # TODO should I have this set for my user...
  nix.settings.trusted-users = [ "root" "${settings.user.username}" ];

  # rate limiting for github
  nix.extraOptions = ''
    !include ${config.age.secrets.github_read_token.path}
  '';

  # nix helper
  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep 3";
    # TODO this may need to be defined higher up if it is ever different for a machine...
    flake = "/home/${settings.user.username}/.config/nixos-config";
  };

  # TODO do I want this dynamic at all? Roaming?
  time.timeZone = "America/Chicago";
  # Select internationalization properties.
  i18n.defaultLocale = defaultLocal;
  i18n.extraLocaleSettings = {
    LC_ADDRESS = defaultLocal;
    LC_IDENTIFICATION = defaultLocal;
    LC_MEASUREMENT = defaultLocal;
    LC_MONETARY = defaultLocal;
    LC_NAME = defaultLocal;
    LC_NUMERIC = defaultLocal;
    LC_PAPER = defaultLocal;
    LC_TELEPHONE = defaultLocal;
    LC_TIME = defaultLocal;
  };

  # Some basics
  nixpkgs.config.allowUnfree = settings.allowUnfree;

  system.stateVersion = "23.11";
}
