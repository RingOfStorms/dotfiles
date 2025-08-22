{
  config,
  ragenix,
  lib,
  pkgs,
  ...
}:

let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "secrets"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  users_cfg = config.${ccfg.custom_config_key}.users;
in
# TODO auto import secret files here
# secretsFile = (settings.secretsDir + /secrets.nix);
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "secrets";
    };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      ragenix.packages.${pkgs.system}.default
      pkgs.rage
    ];

    age = {
      secrets =
        # builtins.mapAttrs
        #   (name: _value: lib.nameValuePair (lib.removeSuffix ".age" name) {
        #     file = (settings.secretsDir + "/${name}");
        #     owner = lib.mkDefault users_cfg.primary;
        #   })
        #   (import secretsFile);
        {
          # nix2github = {
          #   file = ./secrets/nix2github.age;
          #   owner = users_cfg.primary;
          # };
          # nix2bitbucket = {
          #   file = ./secrets/nix2bitbucket.age;
          #   owner = users_cfg.primary;
          # };
          # nix2gitjosh = {
          #   file = ./secrets/nix2gitjosh.age;
          #   owner = users_cfg.primary;
          # };
          # nix2gitforgejo = {
          #   file = ./secrets/nix2gitforgejo.age;
          #   owner = users_cfg.primary;
          # };
          # nix2nix = {
          #   file = ./secrets/nix2nix.age;
          #   owner = users_cfg.primary;
          # };
          # nix2h001 = {
          #   file = ./secrets/nix2h001.age;
          #   owner = users_cfg.primary;
          # };
          # nix2h002 = {
          #   file = ./secrets/nix2h002.age;
          #   owner = users_cfg.primary;
          # };
          # nix2h003 = {
          #   file = ./secrets/nix2h003.age;
          #   owner = users_cfg.primary;
          # };
          # nix2joe = {
          #   file = ./secrets/nix2joe.age;
          #   owner = users_cfg.primary;
          # };
          # nix2gpdPocket3 = {
          #   file = ./secrets/nix2gpdPocket3.age;
          #   owner = users_cfg.primary;
          # };
          # nix2t = {
          #   file = ./secrets/nix2t.age;
          #   owner = users_cfg.primary;
          # };
          # nix2linode = {
          #   file = ./secrets/nix2linode.age;
          #   owner = users_cfg.primary;
          # };
          # nix2oracle = {
          #   file = ./secrets/nix2oracle.age;
          #   owner = users_cfg.primary;
          # };
          # nix2l002 = {
          #   file = ./secrets/nix2l002.age;
          #   owner = users_cfg.primary;
          # };
          # nix2lio = {
          #   file = ./secrets/nix2lio.age;
          #   owner = users_cfg.primary;
          # };
          # nix2oren = {
          #   file = ./secrets/nix2oren.age;
          #   owner = users_cfg.primary;
          # };
          # github_read_token = {
          #   file = ./secrets/github_read_token.age;
          #   owner = users_cfg.primary;
          # };
          # headscale_auth = {
          #   file = ./secrets/headscale_auth.age;
          #   owner = users_cfg.primary;
          # };
          # obsidian_sync_env = {
          #   file = ./secrets/obsidian_sync_env.age;
          #   owner = users_cfg.primary;
          # };
          # us_chi_wg = {
          #   file = ./secrets/us_chi_wg.age;
          #   owner = users_cfg.primary;
          # };
          # zitadel_master_key = {
          #   file = ./secrets/zitadel_master_key.age;
          #   owner = users_cfg.primary;
          #   mode = "444"; # World readable!
          # };
          vaultwarden_env = {
            file = ./secrets/vaultwarden_env.age;
            owner = users_cfg.primary;
            mode = "444"; # World readable!
          };
        };
    };
  };
}
