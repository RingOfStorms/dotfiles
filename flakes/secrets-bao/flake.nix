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

            deepMerge = a: b:
              if builtins.isAttrs a && builtins.isAttrs b then
                builtins.foldl'
                  (acc: key:
                    let
                      newVal = builtins.getAttr key b;
                      mergedVal =
                        if builtins.hasAttr key acc then
                          deepMerge (builtins.getAttr key acc) newVal
                        else
                          newVal;
                    in
                    acc // (builtins.listToAttrs [ { name = key; value = mergedVal; } ])
                  )
                  a
                  (builtins.attrNames b)
              else if builtins.isList a && builtins.isList b then
                a ++ b
              else
                b;

            fragments = builtins.attrValues (builtins.mapAttrs (
              name: s:
              let
                secretPath = s.path or ("/run/secrets/" + name);
              in
              substitute secretPath (s.configChanges or { })
            ) secrets);
          in
          builtins.foldl' deepMerge { } fragments;

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

            deepMerge = a: b:
              if builtins.isAttrs a && builtins.isAttrs b then
                builtins.foldl'
                  (acc: key:
                    let
                      newVal = builtins.getAttr key b;
                      mergedVal =
                        if builtins.hasAttr key acc then
                          deepMerge (builtins.getAttr key acc) newVal
                        else
                          newVal;
                    in
                    acc // (builtins.listToAttrs [ { name = key; value = mergedVal; } ])
                  )
                  a
                  (builtins.attrNames b)
              else if builtins.isList a && builtins.isList b then
                a ++ b
              else
                b;

            fragments = builtins.attrValues (builtins.mapAttrs (
              name: s:
              let
                secretPath = s.path or ("/run/secrets/" + name);
              in
              substitute secretPath (s.hmChanges or { })
            ) secrets);

            merged = builtins.foldl' deepMerge { } fragments;
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
