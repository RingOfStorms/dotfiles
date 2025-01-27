{ ... }:
{
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
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
