{
  inputs = {
    ragenix.url = "github:yaxitech/ragenix";
  };

  outputs =
    {
      ragenix,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            imports = [
              ragenix.nixosModules.age
            ];
            config =
              let
                secretsRaw = import ./secrets.nix;
                systemName = config.networking.hostName;
                # TODO revisit this slightly kinda scary method for choosing owners...
                user =
                  let
                    normalUsers = builtins.filter (name: config.users.users.${name}.isNormalUser or false) (
                      builtins.attrNames config.users.users
                    );
                  in
                  if normalUsers == [ ] then "root" else builtins.head normalUsers;
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
                  "litellm_public_api_key"
                ];

                # Keep only secrets intended for this host (or that include the authority key)
                filteredSecrets = lib.attrsets.filterAttrs (_name: attrs: keepSecret attrs) secretsRaw;
              in
              {
                age.secrets = lib.attrsets.mapAttrs' (
                  name: _attrs:
                  let
                    base = lib.removeSuffix ".age" name;
                  in
                  lib.nameValuePair base (
                    {
                      file = ./. + "/${name}";
                      owner = user;
                    }
                    // lib.optionalAttrs (lib.elem base worldReadable) {
                      mode = "444";
                    }
                  )
                ) filteredSecrets;

              };
          };
      };
    };
}
