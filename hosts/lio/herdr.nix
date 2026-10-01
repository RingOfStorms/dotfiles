{
  inputs,
  lib,
  pkgs,
  ...
}:
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
  terminalBrowser = pkgs.callPackage ./terminal-browser.nix { };
  terminalBrowserSource = pkgs.fetchFromGitHub {
    owner = "zenbu-labs";
    repo = "terminal-browser";
    rev = "v${terminalBrowser.version}";
    hash = "sha256-ZVya0BonXSlxcVby0OsJ5esP5bK6ix7yx7FsgHY+vhM=";
  };
  # `plugin link` skips the manifest's curl-installer build step; Nix provides the binary instead.
  herdrTerminalBrowserPlugin = pkgs.runCommand "herdr-terminal-browser-plugin" { } ''
    cp -r ${terminalBrowserSource}/herdr-plugin "$out"
    chmod -R u+w "$out"
    substituteInPlace "$out/open-split.sh" \
      --replace-fail "command -v terminal-browser" "command -v ${lib.getExe terminalBrowser}" \
      --replace-fail "exec terminal-browser" "exec ${lib.getExe terminalBrowser}"
  '';
  worktreesDirectory = "~/.local/share/git_worktrees/herdr-worktrees";
  integrationTargets = [
    {
      name = "pi";
      directory = "$HOME/.pi/agent";
    }
    {
      name = "omp";
      directory = "$HOME/.omp/agent";
    }
    {
      name = "claude";
      directory = "$HOME/.claude";
    }
    {
      name = "opencode";
      directory = "$HOME/.config/opencode";
    }
    {
      name = "cursor";
      directory = "$HOME/.cursor";
    }
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
  herdrKeys = (pkgs.formats.toml { }).generate "herdr-tmux-keys.toml" {
    keys = {
      prefix = "ctrl+space";

      # Herdr calls a side-by-side split vertical; tmux calls it split-window -h.
      split_vertical = [
        "prefix+|"
        "prefix+shift+backslash"
      ];
      split_horizontal = "prefix+backslash";

      focus_pane_left = [
        "prefix+h"
        "prefix+left"
      ];
      focus_pane_down = [
        "prefix+j"
        "prefix+down"
      ];
      focus_pane_up = [
        "prefix+k"
        "prefix+up"
      ];
      focus_pane_right = [
        "prefix+l"
        "prefix+right"
      ];
      swap_pane_left = "prefix+ctrl+h";
      swap_pane_down = "prefix+ctrl+j";
      swap_pane_up = "prefix+ctrl+k";
      swap_pane_right = "prefix+ctrl+l";

      rename_tab = "prefix+comma";
      close_tab = "prefix+ampersand";
      zoom = "prefix+space";
      # Herdr workspaces are the closest analogue to tmux sessions.
      new_workspace = "prefix+shift+c";
      rename_workspace = "prefix+$";
      previous_workspace = "prefix+(";
      next_workspace = "prefix+)";
      detach = "prefix+ctrl+d";
    };
  };
  pythonWithTomlkit = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  ensureHerdrConfig = pkgs.writeShellScript "herdr-ensure-config" ''
        set -eu
        config="$HOME/.config/herdr/config.toml"
        if [ "''${DRY_RUN:-0}" = 1 ]; then
          echo "Would configure Herdr worktrees and tmux-style keys in $config"
        else
          ${pythonWithTomlkit}/bin/python - "$config" "${herdrKeys}" "${worktreesDirectory}" "${herdr}/bin/herdr" <<'PY'
    import os
    from pathlib import Path
    import stat
    import subprocess
    import sys
    import tempfile

    import tomlkit

    config = Path(sys.argv[1])
    bindings = tomlkit.parse(Path(sys.argv[2]).read_text(encoding="utf-8"))["keys"]
    worktrees_directory = sys.argv[3]
    herdr_bin = sys.argv[4]

    if config.is_symlink():
        raise RuntimeError(f"Refusing to replace symlinked Herdr config: {config}")

    exists = config.exists()
    original = config.read_text(encoding="utf-8") if exists else ""
    document = tomlkit.parse(original)
    if not exists:
        document.add("worktrees", tomlkit.table())
        document["worktrees"]["directory"] = worktrees_directory
    elif document.get("worktrees", {}).get("directory") != worktrees_directory:
        print(
            f"Preserving existing {config}; add [worktrees] directory = "
            f'"{worktrees_directory}" to use the requested worktree root.',
            file=sys.stderr,
        )

    if "keys" not in document:
        document.add("keys", tomlkit.table())
    for action, binding in bindings.items():
        document["keys"][action] = binding

    updated = tomlkit.dumps(document)
    if updated != original:
        config.parent.mkdir(parents=True, exist_ok=True)
        staged = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=config.parent, prefix=".config.toml.", delete=False
            ) as output:
                staged = output.name
                output.write(updated)
            os.chmod(staged, stat.S_IMODE(config.stat().st_mode) if exists else 0o600)
            subprocess.run(
                [herdr_bin, "config", "check"],
                env={**os.environ, "HERDR_CONFIG_PATH": staged},
                check=True,
            )
            os.replace(staged, config)
        finally:
            if staged and os.path.exists(staged):
                os.unlink(staged)
    PY
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

  environment.systemPackages = with pkgs; [
    herdr
    terminalBrowser
    jq
    util-linux
    git
  ];

  home-manager.users.josh = { lib, ... }: {
    home.activation.herdrConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${ensureHerdrConfig}
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

    home.activation.herdrTerminalBrowserPlugin = lib.hm.dag.entryAfter [ "herdrIntegrations" ] ''
      if [ "''${DRY_RUN:-0}" = 1 ]; then
        echo "Would link the Herdr terminal-browser plugin at ${herdrTerminalBrowserPlugin}"
      else
        ${herdr}/bin/herdr plugin link "${herdrTerminalBrowserPlugin}" --enabled
      fi
    '';
  };
}
