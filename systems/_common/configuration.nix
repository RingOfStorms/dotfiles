{ config, lib, pkgs, settings, ylib, ... } @ inputs:
let
  home-manager = builtins.fetchTarball {
    url = "https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz";
    # to get hash run `nix-prefetch-url --unpack "https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz"`
    sha256 = "0g51f2hz13dk953i501fmc6935difhz60741nypaqwz127hy5ldk";
  };
in
{
  imports =
    [
      # Include the results of the hardware scan.
      # Note we need to be in the /etc/nixos directory with this entire config repo for this relative path to work
      (/${settings.systemsDir}/${settings.system.hostname}/hardware-configuration.nix)
      # home manager import
      (import "${home-manager}/nixos")
      ./ragenix.nix
    ];

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Home manager options
  security.polkit.enable = true;
  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = { inherit settings; inherit ylib; inherit (inputs) ragenix; inherit (config) age; };

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

  # Some basics
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
    fzf
    ripgrep

    # TODO keep in common or move to specifics?
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
