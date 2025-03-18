{ ... }:
{
  programs.atuin = {
    enableZshIntegration = true;
    flags = [ "--disable-up-arrow" ];
    settings = {
      workspaces = true;
      exit-mode = "return-query";
      enter_accept = true;
      sync_address = "http://100.64.0.2:8888";
      sync = { records = true; };
    };
  };
}

