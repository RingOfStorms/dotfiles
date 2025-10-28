{ ... }:
# TODO setup auto secret/login for sync
{
  programs.atuin = {
    enable = true;
    enableZshIntegration = true; # TODO make dynamic?
    flags = [ "--disable-up-arrow" ];
    settings = {
      workspaces = true;
      exit-mode = "return-query";
      enter_accept = true;
      sync_address = "https://atuin.joshuabell.xyz";
      sync = {
        records = true;
      };
    };
  };
}
