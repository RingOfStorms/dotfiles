{
  config,
  lib,
  pkgs,
  ...
}:
let
  llm = config.ringofstorms.llm;

  # Background namer for tmux windows/panes (see ai_names.sh). Started from the
  # home-manager tmux config; bundles llm_chat so it does not depend on shell
  # init being sourced in the tmux server's environment.
  tmux-ai-names = pkgs.writeShellApplication {
    name = "tmux-ai-names";
    runtimeInputs = with pkgs; [
      tmux
      curl
      jq
      coreutils
      gnused
      util-linux # flock
    ];
    # Long-running loop: one failed tmux call or vanished /proc entry must not
    # kill it, so skip writeShellApplication's errexit/nounset/pipefail.
    bashOptions = [ ];
    # Baked module defaults; override live with `tmux set -g @ai_names_model`
    # / `@ai_names_reasoning` (the tmux server environment goes stale).
    text = ''
      LLM_BASE_URL=${lib.escapeShellArg llm.baseUrl}
      AI_NAMES_MODEL=${lib.escapeShellArg llm.fast.model}
      AI_NAMES_REASONING=${lib.escapeShellArg (toString llm.fast.reasoning)}
    ''
    + builtins.readFile ../llm/llm.func.sh
    + "\n"
    + builtins.readFile ./ai_names.sh;
  };
in
{
  imports = [ ../llm ];

  environment.systemPackages = [
    pkgs.tmux
    tmux-ai-names
  ];

  environment.shellAliases = {
    tat = "tmux attach-session || tmux new-session";
    t = "tmux";
  };

  environment.shellInit = lib.concatStringsSep "\n\n" [
    (builtins.readFile ./tmux_helpers.sh)
  ];
}
