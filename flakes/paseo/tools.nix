# Primary-user CLI tooling for the paseo container guest.
#
# Pass from the host:
#   ringofstorms.paseo.extraGuestModules = [
#     (inputs.paseo.lib.toolsModule {
#       inherit (inputs) common ros_neovim;
#       hostConfig = config;
#       primaryUser = constants.host.primaryUser;
#     })
#   ];
#
# Everything is system-level (/etc/zshenv, /etc/zshrc, /etc/bashrc,
# /etc/gitconfig, /etc/tmux.conf, ...), so it works for root
# (`nixos-container root-login`) and for the paseo user without Home Manager
# activating dotfiles into the persistent /var/lib/paseo bind mount. Dotfiles
# a user does keep in their home still take precedence.
#
# Shared pieces come from the same sources the host uses for its primary
# user: the common NixOS modules are imported as-is; Home Manager-only
# settings are read from the host's evaluated Home Manager config and fed to
# the equivalent NixOS program modules. Left out on purpose: ssh config/keys,
# atuin sync, GUI tools (meld, terminals, launchers), desktop and host-service
# modules.
{
  common,
  ros_neovim,
  hostConfig,
  primaryUser,
}:
{ lib, pkgs, ... }:
let
  hostHm = hostConfig.home-manager.users.${primaryUser};
  hmZsh = hostHm.programs.zsh;

  # The common git module also installs meld (GUI); take the rest of it.
  gitCommon = common.nixosModules.git { inherit lib pkgs; };

  gitIgnore = pkgs.writeText "gitignore" (lib.concatLines hostHm.programs.git.ignores);
  difftCommand = "${lib.getExe pkgs.difftastic} ${lib.cli.toCommandLineShellGNU { } hostHm.programs.difftastic.options}";

  keymapFlag = {
    emacs = "-e";
    viins = "-v";
    vicmd = "-a";
  };
in
{
  imports = [
    common.nixosModules.essentials
    common.nixosModules.tmux
    common.nixosModules.zsh
    common.nixosModules.rage
    common.nixosModules.timezone_chi
    ros_neovim.nixosModules.default
  ];

  "ringofstorms-nvim" = {
    inherit (hostConfig."ringofstorms-nvim") includeAllRuntimeDependencies underPrefix;
  };

  environment.systemPackages =
    builtins.filter (p: lib.getName p != "meld") gitCommon.environment.systemPackages
    ++ [ pkgs.difftastic ];
  environment.shellAliases = gitCommon.environment.shellAliases;
  environment.shellInit = gitCommon.environment.shellInit;

  # Paseo's daemon runs `git diff` (without --no-ext-diff) as this user to
  # render its diff views, so difftastic stays out of /etc/gitconfig and is
  # only set for interactive shells.
  environment.interactiveShellInit = ''
    export GIT_EXTERNAL_DIFF=${lib.escapeShellArg difftCommand}
  '';

  programs.git = {
    enable = true;
    # meld is not installed in the guest.
    config = lib.recursiveUpdate (removeAttrs hostHm.programs.git.settings [
      "merge"
      "mergetool"
    ]) { core.excludesFile = "${gitIgnore}"; };
  };

  programs.zsh = {
    autosuggestions.enable = hmZsh.autosuggestion.enable;
    histSize = hmZsh.history.size;
    # All init is system-wide and homes carry no zsh dotfiles, so keep zsh's
    # first-run .zshrc wizard from prompting (it would only write a stub).
    shellInit = ''
      zsh-newuser-install() { :; }
    '';
    # The shared zsh init (keybindings, ephemeral history, completion
    # styles, EDITOR) is the common Home Manager module's own text.
    interactiveShellInit = ''
      ${lib.optionalString (hmZsh.defaultKeymap != null) "bindkey ${keymapFlag.${hmZsh.defaultKeymap}}"}
      ${(common.homeManagerModules.zsh { }).programs.zsh.initContent}
    '';
  };

  programs.starship = {
    enable = true;
    inherit (hostHm.programs.starship) settings;
  };

  programs.zoxide = {
    enable = true;
    flags = hostHm.programs.zoxide.options;
  };

  programs.direnv = {
    enable = true;
    settings = hostHm.programs.direnv.config;
  };

  # Local history only: no sync server or account in the container.
  programs.atuin = {
    enable = true;
    inherit (hostHm.programs.atuin) flags;
    settings = removeAttrs hostHm.programs.atuin.settings [
      "sync_address"
      "sync"
    ] // {
      auto_sync = false;
      update_check = false;
    };
    daemon.enable = false;
  };

  environment.etc."tmux.conf".source = hostHm.xdg.configFile."tmux/tmux.conf".source;

  # Paseo web terminals run "$SHELL" from the daemon's environment (else
  # /bin/sh) as a non-login interactive shell. zsh reads /etc/zshenv for every
  # shell, which loads /etc/set-environment (system PATH) before the
  # interactive setup above.
  services.paseo.environment.SHELL = "${pkgs.zsh}/bin/zsh";

  # Same shell for `su - paseo` / `machinectl shell paseo@paseo` as for Paseo
  # terminals: the shared essentials init uses zsh-only syntax, so bash login
  # shells stop partway through /etc/profile (the hosts' own bash does the
  # same). Forced because the container module shares one users.users.paseo
  # definition between host and guest; only the guest changes here.
  users.users.paseo.shell = lib.mkForce pkgs.zsh;
}
