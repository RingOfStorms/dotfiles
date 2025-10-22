{
  config,
  lib,
  ...
}:
{
  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Allow unfree if set in config
  nixpkgs.config.allowUnfreePredicate = lib.mkIf config.nixpkgs.config.allowUnfree (pkg: true);
  environment.variables = lib.mkIf config.nixpkgs.config.allowUnfree {
    NIXPKGS_ALLOW_UNFREE = "1";
  };

  nix.settings = {
    max-jobs = "auto";
    # Fallback quickly if substituters are not available.
    connect-timeout = 5;
    download-attempts = 3;
    download-buffer-size = 524288000; # default is 67108864, this increases to ~500MB
    # The default at 10 is rarely enough.
    log-lines = 50;
    # Avoid disk full issues
    max-free = (3000 * 1024 * 1024);
    min-free = (1000 * 1024 * 1024);
    # Avoid copying unnecessary stuff over SSH
    builders-use-substitutes = true;
    auto-optimise-store = true;
    trusted-users = [
      "root"
      "@wheel"
    ];
    substituters = [
      "https://cache.nixos.org/"
      "https://nix-community.cachix.org"
    ];
    trusted-substituters = config.nix.settings.substituters;
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
  nix.extraOptions = ''
    keep-outputs = true
    keep-derivations = true
    ${lib.optionalString (
      # TODO revisit this should it move?
      config ? age && config.age ? secrets && config.age.secrets ? github_read_token
    ) "!include ${config.age.secrets.github_read_token.path}"}
  '';

  # nix helper
  programs.nh = {
    enable = true;
    # clean.enable = true; # TODO revist does this solve my re-building issues?
    clean.extraArgs = "--keep 10";
  };
}
