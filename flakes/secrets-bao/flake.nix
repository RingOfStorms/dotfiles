{
  description = "Runtime secrets via OpenBao + Zitadel machine key";

  inputs = { };

  outputs = { ... }:
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

      applyConfigChanges = secrets:
        let
          fragments = builtins.attrValues (builtins.mapAttrs (
            name: s:
            let
              secretPath = s.path or ("/var/lib/openbao-secrets/" + name);
            in
            substitute secretPath (s.configChanges or { })
          ) secrets);
        in
        builtins.foldl' deepMerge { } fragments;

      applyHmChanges = secrets:
        let
          fragments = builtins.attrValues (builtins.mapAttrs (
            name: s:
            let
              secretPath = s.path or ("/var/lib/openbao-secrets/" + name);
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

      # Hardcoded list of SSH matchBlock hosts from the shared ssh.nix HM module.
      # Keep in sync with flakes/common/hm_modules/ssh.nix.
      nix2nixMatchBlockHosts = [
        "lio" "lio_"
        "oren"
        "juni"
        "gp3"
        "joe"
        "t" "t_"
        "h001" "h001_"
        "h002" "h002_"
        "h003" "h003_"
        "l001"
        "l002" "l002_"
        "o001" "o001_"
      ];

      # Generate common secrets based on role and primary user.
      # Returns an attrset suitable for ringofstorms.secretsBao.secrets.
      #
      # Usage in host flake.nix:
      #   secrets = inputs.secrets-bao.lib.mkAutoSecrets {
      #     role = "machines-hightrust";    # or "machines-lowtrust"
      #     primaryUser = "josh";           # owner of SSH key secrets
      #   };
      mkAutoSecrets =
        { role
        , primaryUser ? "root"
        , basePath ? "/var/lib/openbao-secrets"
        , headscaleAuth ? true
        , nix2nix ? true
        , nix2github ? true
        , nix2gitforgejo ? true
        , githubReadToken ? true
        }:
        let
          isHighTrust = role == "machines-hightrust";
          isLowTrust = role == "machines-lowtrust";
          group = if primaryUser == "root" then "root" else "users";

          kvPrefix =
            if isHighTrust then "kv/data/machines/high-trust"
            else if isLowTrust then "kv/data/machines/low-trust"
            else null;

          headscaleSecretName =
            if isHighTrust then "headscale_auth_2026-03-15"
            else "headscale_auth_lowtrust_2026-03-15";

          headscale =
            if headscaleAuth && kvPrefix != null then {
              ${headscaleSecretName} = {
                kvPath = "${kvPrefix}/${headscaleSecretName}";
                softDepend = [ "tailscaled" ];
                configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
              };
            }
            else { };

          sshNix2Nix =
            if nix2nix && isHighTrust then {
              "nix2nix_2026-03-15" = {
                owner = primaryUser;
                inherit group;
                hmChanges.programs.ssh.matchBlocks = builtins.listToAttrs (
                  map (host: {
                    name = host;
                    value = { identityFile = "$SECRET_PATH"; };
                  }) nix2nixMatchBlockHosts
                );
              };
            }
            else { };

          sshGithub =
            if nix2github && isHighTrust then {
              "nix2github_2026-03-15" = {
                owner = primaryUser;
                inherit group;
                hmChanges.programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
              };
            }
            else { };

          sshForgejo =
            if nix2gitforgejo && isHighTrust then {
              "nix2gitforgejo_2026-03-15" = {
                owner = primaryUser;
                inherit group;
                hmChanges.programs.ssh.matchBlocks."git.joshuabell.xyz".identityFile = "$SECRET_PATH";
              };
            }
            else { };

          ghToken =
            if githubReadToken && isHighTrust then {
              "github_read_token_2026-03-15" = {
                configChanges.nix.extraOptions = "!include $SECRET_PATH";
              };
            }
            else { };
        in
        headscale // sshNix2Nix // sshGithub // sshForgejo // ghToken;
    in
    {
      lib = {
        inherit applyConfigChanges applyHmChanges mkAutoSecrets;

        applyChanges = secrets:
          deepMerge (applyConfigChanges secrets) (applyHmChanges secrets);
      };

      nixosModules = {
        default = import ./nixos-module.nix;
      };
    };
}
