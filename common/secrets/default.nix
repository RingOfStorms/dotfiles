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

  secretsRaw = import ./secrets/secrets.nix;
  systemName = lib.attrsets.getAttrFromPath [
    ccfg.custom_config_key
    "systemName"
  ] config;
  authorityMarker = "authority";

  # Key matches this host if its trailing comment contains "@<host>"
  matchesThisSystem = key: lib.strings.hasInfix "@${systemName}" key;
  # Key is the authority key if its comment contains the marker string
  matchesAuthority = key: lib.strings.hasInfix authorityMarker key;

  keepSecret =
    attrs:
    let
      keys = attrs.publicKeys or [ ];
    in
    lib.any (k: matchesThisSystem k) keys;

  # Any secrets that should be world-readable even after auto-import
  worldReadable = [
    "zitadel_master_key"
    "openwebui_env"
    "vaultwarden_env"
  ];

  # Keep only secrets intended for this host (or that include the authority key)
  filteredSecrets = lib.attrsets.filterAttrs (_name: attrs: keepSecret attrs) secretsRaw;
in
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
      secrets = lib.attrsets.mapAttrs' (
        name: _attrs:
        let
          base = lib.removeSuffix ".age" name;
        in
        lib.nameValuePair base (
          {
            file = ./. + "/secrets/${name}";
            owner = users_cfg.primary;
          }
          // lib.optionalAttrs (lib.elem base worldReadable) {
            mode = "444";
          }
        )
      ) filteredSecrets;
    };
  };
}
