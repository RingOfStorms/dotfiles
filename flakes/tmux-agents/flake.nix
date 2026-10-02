{
  description = "tmux-agents: agent state, repo/worktree navigator and agent resume for tmux";

  # No inputs: the plugin builds against the consumer's pkgs so tmux, fzf and
  # git match the rest of the system.
  inputs = { };

  outputs =
    { self, ... }:
    {
      lib.mkPlugin =
        pkgs:
        let
          app = pkgs.writeShellApplication {
            name = "tmux-agents";
            # Errexit stays off: the tick must degrade, not abort, when a pane
            # disappears between list-panes and set-option.
            bashOptions = [
              "nounset"
              "pipefail"
            ];
            # tmux itself comes from PATH so the client always matches the
            # running server.
            runtimeInputs = with pkgs; [
              coreutils
              curl
              fzf
              git
              libnotify
              procps
              sqlite
              util-linux
            ];
            text = builtins.replaceStrings [ "@resume_lib@" ] [ "${./resume.sh}" ] (
              builtins.readFile ./tmux-agents.sh
            );
          };
        in
        pkgs.tmuxPlugins.mkTmuxPlugin {
          pluginName = "tmux-agents";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = ./tmux_agents.tmux;
          };
          postInstall = ''
            mkdir -p $target/bin
            ln -s ${app}/bin/tmux-agents $target/bin/tmux-agents
          '';
        };

      # Same module, switched on; mkDefault keeps `enable = false` possible.
      homeManagerModules.defaultEnabled =
        { lib, ... }:
        {
          imports = [ self.homeManagerModules.default ];
          ringofstorms.tmuxAgents.enable = lib.mkDefault true;
        };

      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.ringofstorms.tmuxAgents;
          n = cfg.notifications;
          onOff = b: if b then "on" else "off";
          plugin = self.lib.mkPlugin pkgs;
        in
        {
          options.ringofstorms.tmuxAgents = {
            enable = lib.mkEnableOption "agent-aware tmux navigator, status and resume";
            key = lib.mkOption {
              type = lib.types.str;
              default = "w";
              description = "Prefix key that opens the agents navigator popup.";
            };
            notifications = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Master switch for all agent notifications (finished/needs input while unseen).";
              };
              desktop = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Desktop notification (notify-send) on the machine running tmux.";
              };
              message = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "tmux message on every attached client; reaches ssh/mobile clients.";
              };
              sound = lib.mkOption {
                type = lib.types.enum [
                  "off"
                  "local"
                  "bell"
                ];
                default = "local";
                description = ''
                  "local" plays a sound file on the tmux host (pw-play/paplay);
                  "bell" sends a terminal bell to each attached client (ssh/mobile beep or vibrate).
                '';
              };
              soundDone = lib.mkOption {
                type = lib.types.str;
                default = "${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/complete.oga";
                description = "Sound played for a finished agent when sound = \"local\".";
              };
              soundInput = lib.mkOption {
                type = lib.types.str;
                default = "${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/dialog-warning.oga";
                description = "Sound played for an agent needing input when sound = \"local\".";
              };
              doneVolume = lib.mkOption {
                type = lib.types.ints.between 0 100;
                default = 15;
                description = "Playback volume in percent of the finished sound (sound = \"local\").";
              };
              inputVolume = lib.mkOption {
                type = lib.types.ints.between 0 100;
                default = 90;
                description = "Playback volume in percent of the needs-input sound (sound = \"local\").";
              };
            };
            resume = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  tmux-resurrect integration (resume.sh): track which omp or opencode session
                  each agent pane runs and resume it after a restore. Off removes the resurrect hooks.
                '';
              };
              mode = lib.mkOption {
                type = lib.types.enum [
                  "auto"
                  "prompt"
                ];
                default = "auto";
                description = ''
                  "auto" runs the resume command in each restored agent pane;
                  "prompt" only types it at the shell prompt for you to confirm.
                '';
              };
              ompCommand = lib.mkOption {
                type = lib.types.str;
                default = "omp --resume=";
                description = "Command prefix that resumes an omp session; the session file path is appended.";
              };
              opencodeCommand = lib.mkOption {
                type = lib.types.str;
                default = "opencode -s ";
                description = "Command prefix that resumes an opencode session; the session ID is appended.";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            # Continuum may restore before the late theme/status loader runs.
            xdg.configFile."tmux/tmux.conf".text = lib.mkBefore ''
              set -g @tmux-agents-resume '${onOff cfg.resume.enable}'
              set -g @tmux-agents-resume-mode '${cfg.resume.mode}'
              set -g @tmux-agents-resume-command '${cfg.resume.ompCommand}'
              set -g @tmux-agents-resume-command-opencode '${cfg.resume.opencodeCommand}'
              run-shell '${plugin}/share/tmux-plugins/tmux-agents/bin/tmux-agents resume-init'
            '';
            # mkAfter: must load after catppuccin (formats) and resurrect.
            programs.tmux.plugins = lib.mkAfter [
              {
                inherit plugin;
                extraConfig = ''
                  set -g @tmux-agents-key '${cfg.key}'
                  set -g @tmux-agents-notify '${onOff n.enable}'
                  set -g @tmux-agents-notify-desktop '${onOff n.desktop}'
                  set -g @tmux-agents-notify-message '${onOff n.message}'
                  set -g @tmux-agents-notify-sound '${n.sound}'
                  set -g @tmux-agents-sound-done '${n.soundDone}'
                  set -g @tmux-agents-sound-input '${n.soundInput}'
                  set -g @tmux-agents-sound-done-volume '${toString n.doneVolume}'
                  set -g @tmux-agents-sound-input-volume '${toString n.inputVolume}'
                  set -g @tmux-agents-resume '${onOff cfg.resume.enable}'
                  set -g @tmux-agents-resume-mode '${cfg.resume.mode}'
                  set -g @tmux-agents-resume-command '${cfg.resume.ompCommand}'
                  set -g @tmux-agents-resume-command-opencode '${cfg.resume.opencodeCommand}'
                '';
              }
            ];
          };
        };
    };
}
