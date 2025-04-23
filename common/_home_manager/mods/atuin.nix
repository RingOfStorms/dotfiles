{ ... }:
{
  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
    flags = [ "--disable-up-arrow" ];
    settings = {
      workspaces = true;
      exit-mode = "return-query";
      enter_accept = true;
      sync_address = "https://atuin.joshua.xyz";
      sync = { records = true; };
    };
  };
}

