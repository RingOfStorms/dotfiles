{
  description = "Runtime secrets via OpenBao + Zitadel machine key";

  inputs = { };

  outputs = { ... }:
    {
      lib = {
        applyConfigChanges = secrets:
          let
            substitute = secretPath: value:
              if builtins.isAttrs value then
                builtins.mapAttrs (_: v: substitute secretPath v) value
              else if builtins.isList value then
                map (v: substitute secretPath v) value
              else if builtins.isString value then
                builtins.replaceStrings [ "$SECRET_PATH" ] [ secretPath ] value
              else
                value;

            fragments = builtins.attrValues (builtins.mapAttrs (
              name: s:
              let
                secretPath = s.path or ("/run/secrets/" + name);
              in
              substitute secretPath (s.configChanges or { })
            ) secrets);
          in
          builtins.foldl' (acc: v: acc // v) { } fragments;

        applyHmChanges = secrets:
          let
            substitute = secretPath: value:
              if builtins.isAttrs value then
                builtins.mapAttrs (_: v: substitute secretPath v) value
              else if builtins.isList value then
                map (v: substitute secretPath v) value
              else if builtins.isString value then
                builtins.replaceStrings [ "$SECRET_PATH" ] [ secretPath ] value
              else
                value;

            fragments = builtins.attrValues (builtins.mapAttrs (
              name: s:
              let
                secretPath = s.path or ("/run/secrets/" + name);
              in
              substitute secretPath (s.hmChanges or { })
            ) secrets);

            merged = builtins.foldl' (acc: v: acc // v) { } fragments;
          in
          if merged == { } then
            { }
          else
            {
              home-manager.sharedModules = [ (_: merged) ];
            };
      };

      nixosModules = {
        default = import ./nixos-module.nix;
      };
    };
}
