{ ... }:
# Auto secret/login for sync is handled system-side by the
# `ringofstorms.atuin` module (flakes/common/nix_modules/atuin.nix),
# which logs the user into the sync server on boot from a secrets file.
{
  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
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
