{ settings, ... }:
{
  ##### I want to hide the output but couldn't get either of these to work
  # home.sessionVariables = {
  # DIRENV_LOG_FORMAT = "";
  # };
  # programs.zsh.initExtra = ''
  #   copy_function() {
  #     test -n "$(declare -f "$1")" || return
  #     eval "''${_/$1/$2}"
  #   }
  #   copy_function _direnv_hook _direnv_hook__old
  #   _direnv_hook() {
  #     # old line
  #     #_direnv_hook__old "$@" 2> >(grep -E -v '^direnv: (export)')

  #     # my new line
  #     _direnv_hook__old "$@" 2> >(awk '{if (length >= 200) { sub("^direnv: export.*","direnv: export "NF" environment variables")}}1')

  #     # as suggested by user "radekh" above
  #     wait

  #     # as suggested by user "Ic-guy" below if you're using bash > v4.4
  #     # throws error for me on zsh
  #     # wait $!
  #   }
  # '';
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    config = {
      nix-direnv = true;
      global = {
        strict_env = true;
        load_dotenv = true;
        hide_env_diff = true;
      };
      whitelist = {
        prefix = [
          "~/projects"
          "~/.config"
        ];
      };
    };
  };
}
