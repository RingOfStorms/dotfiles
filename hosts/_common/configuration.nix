{ pkgs, settings, ... }:
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

  # ==========
  #   Common
  # ==========
  networking = {
    hostName = settings.system.hostname;
    extraHosts = ''
      127.0.0.1 local.belljm.com
      127.0.0.1 n0.local.belljm.com
      127.0.0.1 n1.local.belljm.com
      127.0.0.1 n2.local.belljm.com
      127.0.0.1 n3.local.belljm.com
      127.0.0.1 n4.local.belljm.com
    '';
    # Use nftables not iptables
    nftables.enable = true;
    firewall.enable = true;
  };
  # TODO do I want this dynamic at all? Roaming?
  time.timeZone = "America/Chicago";

  # nix helper
  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep 3";
    # TODO this may need to be defined higher up if it is ever different for a machine...
    flake = "/home/${settings.user.username}/.config/nixos-config";
  };

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
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # Basics
    vim
    wget
    curl
    fastfetch
    bat
    htop
    unzip
    git
    fzf
    ripgrep
    lsof

    # TODO keep in common or move to specific machines, I want this for my pocket 3 video KDM module but I use ffmpeg on most machines anyways?
    ffmpeg-full
  ];

  environment.shellAliases = {
    n = "nvim";
    nn = "nvim --headless '+SessionDelete' +qa > /dev/null 2>&1 && nvim";
    bat = "bat --theme Coldark-Dark";
    cat = "bat --pager=never -p";
    # TODO this may not be needed now that I am using `nh` clean mode (see /hosts/_common/configuration.nix#programs.nh)
    nix-boot-clean = "find '/boot/loader/entries' -type f ! -name 'windows.conf' | head -n -4 | xargs -I {} rm {}; nix store gc; nixos-rebuild boot; echo; df";

    # general unix
    date_compact = "date +'%Y%m%d'";
    date_short = "date +'%Y-%m-%d'";
    ls = "ls --color -Ga";
    ll = "ls --color -Gal";
    lss = "du --max-depth=0 -h * 2>/dev/null";
    psg = "ps aux | head -n 1 && ps aux | grep -v 'grep' | grep";
    cl = "clear";

    # git
    stash = "git stash";
    pop = "git stash pop";
    branch = "git checkout -b";
    status = "git status";
    diff = "git diff";
    branches = "git branch -a";
    gcam = "git commit -a -m";
    stashes = "git stash list";

    # ripgrep
    rg = "rg --no-ignore";
    rgf = "rg --files 2>/dev/null | rg";

    # Neofetch is dead
    neofetch = "fastfetch";

    # Nix deprecations
    nix-hash = "echo 'The functionality of nix-hash may be covered by various subcommands or options in the new `nix` command.'";
    nix-build = "echo 'Use `nix build` instead.'";
    nix-info = "echo 'Use `nix flake info` or other `nix` subcommands to obtain system and Nix information.'";
    nix-channel = "echo 'Channels are being phased out in favor of flakes. Use `nix flake` subcommands.'";
    nix-instantiate = "echo 'Use `nix eval` or `nix-instantiate` with flakes.'";
    nix-collect-garbage = "echo 'Use `nix store gc` instead.'";
    nix-prefetch-url = "echo 'Use `nix-prefetch` or fetchers in Nix expressions.'";
    nix-copy-closure = "echo 'Use `nix copy` instead.'";
    nix-shell = "echo 'Use `nix shell` instead.'";
    # nix-daemon # No direct replacement: The Nix daemon is still in use and managed by the system service manager.
    nix-store = "echo 'Use `nix store` subcommands for store operations.'";
    nix-env = "echo 'Use `nix profile` instead'";
  };
  environment.shellInit = builtins.readFile ./shellInit.sh;

  system.stateVersion = "23.11";
}
