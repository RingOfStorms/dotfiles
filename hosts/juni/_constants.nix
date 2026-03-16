# Service constants for juni (Framework 12 Laptop)
# Primarily a desktop with impermanence. Minimal services.
{
  host = {
    name = "juni";
    primaryUser = "josh";
    stateVersion = "25.11";
  };

  secrets = {
    "headscale_auth_2026-03-15" = {
      softDepend = [ "tailscaled" ];
      configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
    };
    "atuin-key-josh_2026-03-15" = {
      owner = "josh";
      group = "users";
      mode = "0400";
      hardDepend = [ "atuin-autologin" ];
      template = ''{{- with secret "kv/data/machines/high-trust/atuin-key-josh_2026-03-15" -}}{{ printf "%s\n%s\n%s" .Data.data.user .Data.data.password .Data.data.value }}{{- end -}}'';
    };
    "nix2github_2026-03-15" = {
      owner = "josh";
      group = "users";
      hmChanges.programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
    };
    "nix2gitforgejo_2026-03-15" = {
      owner = "josh";
      group = "users";
      hmChanges.programs.ssh.matchBlocks."git.joshuabell.xyz".identityFile = "$SECRET_PATH";
    };
    "nix2nix_2026-03-15" = {
      owner = "josh";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks = {
          "lio".identityFile = "$SECRET_PATH";
          "lio_".identityFile = "$SECRET_PATH";
          "oren".identityFile = "$SECRET_PATH";
          "juni".identityFile = "$SECRET_PATH";
          "gp3".identityFile = "$SECRET_PATH";
          "t".identityFile = "$SECRET_PATH";
          "t_".identityFile = "$SECRET_PATH";
          "h001".identityFile = "$SECRET_PATH";
          "h001_".identityFile = "$SECRET_PATH";
          "h002".identityFile = "$SECRET_PATH";
          "h002_".identityFile = "$SECRET_PATH";
          "h003".identityFile = "$SECRET_PATH";
          "h003_".identityFile = "$SECRET_PATH";
          "l001".identityFile = "$SECRET_PATH";
          "l002".identityFile = "$SECRET_PATH";
          "l002_".identityFile = "$SECRET_PATH";
          "o001".identityFile = "$SECRET_PATH";
          "o001_".identityFile = "$SECRET_PATH";
        };
      };
    };
    "github_read_token_2026-03-15" = {
      configChanges = {
        nix.extraOptions = "!include $SECRET_PATH";
      };
    };
  };
}
