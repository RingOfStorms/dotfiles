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

  nix.settings = {
    max-jobs = "auto";
    # Fallback quickly if substituters are not available.
    connect-timeout = 5;
    download-attempts = 3;
    # The default at 10 is rarely enough.
    log-lines = 50;
    # Avoid disk full issues
    max-free = (3000 * 1024 * 1024);
    min-free = (1000 * 1024 * 1024);
    # Avoid copying unnecessary stuff over SSH
    builders-use-substitutes = true;
    # Slower but more robust during crash TODO enable once we upgrade nix
    # fsync-store-paths = true;
    # fsync-metadata = true;
    auto-optimise-store = true;

    # TODO should I have this set for my user...
    trusted-users = [
      "root"
      "${settings.user.username}"
    ];
  };


  # rate limiting for github
  nix.extraOptions = ''
    keep-outputs = true
    keep-derivations = true
    !include ${config.age.secrets.github_read_token.path}
  '';

  # nix helper
  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep 10";
    # TODO this may need to be defined higher up if it is ever different for a machine...
    flake = "/home/${settings.user.username}/.config/nixos-config";
  };

  # Remote build off home lio computer
  programs.ssh.extraConfig = ''
    Host lio_
      PubkeyAcceptedKeyTypes ssh-ed25519
      ServerAliveInterval 60
      IPQoS throughput
      IdentityFile ${config.age.secrets.nix2lio.path}
  '';
  nix = {
    distributedBuilds = true;
    buildMachines = [
      {
        hostName = "lio_";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        maxJobs = 32;
        speedFactor = 2;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
          "uid-range" # Often helpful
        ];
        mandatoryFeatures = [ ];
      }
    ];
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
  nixpkgs.config.allowUnfreePredicate = (pkg: true);
}
