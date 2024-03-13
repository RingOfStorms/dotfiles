{ settings, ... }:
{
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    config = {
      global = {
        strict_env = true;
        load_dotenv = true;
        hide_env_diff = true;
      };
      whitelist = {
        prefix = [ "~/projects" ];
      };
    };
  };
}

