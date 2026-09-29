{ inputs, lib, pkgs, ... }:
let
  herdr = inputs.herdr-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  gitModule = ../../flakes/common/nix_modules/git;
  herdrGitPlugin = pkgs.runCommand "herdr-git-plugin" { } ''
    mkdir -p "$out"
    cp ${gitModule}/plugin/herdr-plugin.toml "$out/herdr-plugin.toml"
    cp ${gitModule}/plugin/bootstrap.sh "$out/bootstrap.sh"
    cp ${gitModule}/plugin/worktree_setup.sh "$out/worktree_setup.sh"
    cp ${gitModule}/link_ignored.func.sh "$out/link_ignored.func.sh"
  '';
  worktreesDirectory = "~/.local/share/git_worktrees/herdr-worktrees";
  integrationTargets = [
    { name = "pi"; directory = "$HOME/.pi/agent"; }
    { name = "omp"; directory = "$HOME/.omp/agent"; }
    { name = "claude"; directory = "$HOME/.claude"; }
    { name = "opencode"; directory = "$HOME/.config/opencode"; }
    { name = "cursor"; directory = "$HOME/.cursor"; }
  ];
  installIntegrations = pkgs.writeShellScript "herdr-install-integrations" ''
    set -eu
    status="$(${herdr}/bin/herdr integration status)"
    ${lib.concatMapStringsSep "\n" (target: ''
      if [ -d "${target.directory}" ] && ! printf '%s\n' "$status" | ${pkgs.gnugrep}/bin/grep -Fq '${target.name}: current ('; then
        ${herdr}/bin/herdr integration install ${target.name}
        status="$(${herdr}/bin/herdr integration status)"
      fi
    '') integrationTargets}
  '';
  ensureWorktreeConfig = pkgs.writeShellScript "herdr-ensure-worktree-config" ''
    set -eu
    config="$HOME/.config/herdr/config.toml"
    if [ ! -e "$config" ]; then
      if [ "''${DRY_RUN:-0}" = 1 ]; then
        echo "Would create $config with Herdr worktree directory ${worktreesDirectory}"
      else
        mkdir -p "$(dirname "$config")"
        ${pkgs.coreutils}/bin/printf '%s\n' \
          '[worktrees]' \
          'directory = "${worktreesDirectory}"' > "$config"
      fi
    elif ! ${pkgs.gnugrep}/bin/grep -Fq 'directory = "${worktreesDirectory}"' "$config"; then
      echo "Preserving existing $config; add [worktrees] directory = \"${worktreesDirectory}\" to use the requested worktree root." >&2
    fi
  '';
in
{
  nix.settings = {
    substituters = lib.mkAfter [ "https://herdr.cachix.org" ];
    trusted-public-keys = lib.mkAfter [
      "herdr.cachix.org-1:3nH7IStRsS0ASfdonA0DCRR2ZrSCeWitZ7Kwew0cR4I="
    ];
  };

  environment.systemPackages = with pkgs; [ herdr jq util-linux git ];

  home-manager.users.josh = { lib, ... }: {
    home.activation.herdrConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${ensureWorktreeConfig}
    '';

    home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "herdrConfig" ] ''
      if [ "''${DRY_RUN:-0}" = 1 ]; then
        echo "Would install current Herdr integrations for configured native agents"
      else
        ${installIntegrations}
      fi
    '';

    home.activation.herdrGitPlugin = lib.hm.dag.entryAfter [ "herdrIntegrations" ] ''
      if [ "''${DRY_RUN:-0}" = 1 ]; then
        echo "Would link the Herdr Git worktree plugin at ${herdrGitPlugin}"
      else
        ${herdr}/bin/herdr plugin link "${herdrGitPlugin}"
      fi
    '';
  };
}
