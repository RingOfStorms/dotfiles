{ config, lib, pkgs, settings, ylib, ... } @ inputs:
let
  defaultLocal = "en_US.UTF-8";
in
{
  imports =
    [
      # Secrets management
      ./ragenix.nix
      # Include the results of the hardware scan.
      (/${settings.hostsDir}/${settings.system.hostname}/hardware-configuration.nix)
      # Include the specific machine's config.
      (/${settings.hostsDir}/${settings.system.hostname}/configuration.nix)
    ];

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ==========
  #   Common
  # ==========
  networking.hostName = settings.system.hostname;
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
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # Basics
    # neovim in TODO nix file in common, to split out into its own flake eventually
    vim
    wget
    curl
    neofetch
    bat
    htop
    nvtop
    unzip
    git
    fzf
    ripgrep

    # TODO keep in common or move to specific machines, I want this for my pocket 3 video KDM module but I use ffmpeg on most machines anyways?
    ffmpeg_5-full
  ];

  environment.shellAliases = {
    n = "nvim";
    nn = "nvim --headless '+SessionDelete' +qa > /dev/null 2>&1 && nvim";
    bat = "bat --theme Coldark-Dark";
    cat = "bat --pager=never -p";
    nix-boot-clean = "find '/boot/loader/entries' -type f ! -name 'windows.conf' | head -n -4 | xargs -I {} rm {}; nix-collect-garbage -d; nixos-rebuild boot; echo; df";

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
  };
  environment.shellInit = builtins.readFile ./shellInit.sh;

  system.stateVersion = "23.11";
}