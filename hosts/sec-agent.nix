# Shared sec-agent configuration for hosts that have left secrets-bao.
#
# Host flakes pass the trust role and only their host-specific secrets. Keeping
# the fleet-wide definitions here means the SSH identity, GitHub/Forgejo key,
# GitHub read token, and headscale mapping cannot drift from one host to another.
{
  inputs,
  constants,
  role,
  extraSecrets ? { },
  secretsDir ? "/var/lib/secrets_manager_hydrated",
}:
let
  lib = inputs.nixpkgs.lib;
  primaryUser = constants.host.primaryUser;
  group = if primaryUser == "root" then "root" else "users";

  # Must match hosts/fleet.nix and flakes/secrets-bao/flake.nix. The old
  # OpenBao module generated these SSH match blocks automatically; sec-agent
  # keeps that behavior without depending on the old input.
  nix2nixMatchBlockHosts = [
    "lio" "lio_"
    "oren"
    "juni" "juni_"
    "gp3" "gp3_"
    "joe" "joe_"
    "i001" "i001_"
    "t" "t_"
    "h001" "h001_"
    "h002" "h002_"
    "h003" "h003_"
    "l002" "l002_"
    "o002" "o002_"
  ];

  isHighTrust = role == "machines-hightrust";
  trustPath = if isHighTrust then "high-trust" else "low-trust";

  commonSecrets = {
    "headscale_auth_${if isHighTrust then "2026-03-15" else "lowtrust_2026-03-15"}" = {
      remotePath = "machines/${trustPath}/headscale_auth_${if isHighTrust then "2026-03-15" else "lowtrust_2026-03-15"}";
      softDepend = [ "tailscaled" ];
      configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
    };
  }
  // lib.optionalAttrs isHighTrust {
    "nix2nix_2026-03-15" = {
      remotePath = "machines/high-trust/nix2nix_2026-03-15";
      inherit group;
      owner = primaryUser;
      ensureNewline = true;
      hmChanges.programs.ssh.settings = builtins.listToAttrs (
        map (host: {
          name = host;
          value = { IdentityFile = "$SECRET_PATH"; };
        }) nix2nixMatchBlockHosts
      );
    };

    "nix2github_2026-03-15" = {
      remotePath = "machines/high-trust/nix2github_2026-03-15";
      inherit group;
      owner = primaryUser;
      ensureNewline = true;
      hmChanges.programs.ssh.settings."github.com".IdentityFile = "$SECRET_PATH";
    };

    "nix2gitforgejo_2026-03-15" = {
      remotePath = "machines/high-trust/nix2gitforgejo_2026-03-15";
      inherit group;
      owner = primaryUser;
      ensureNewline = true;
      hmChanges.programs.ssh.settings."git.joshuabell.xyz".IdentityFile = "$SECRET_PATH";
    };

    "github_read_token_2026-03-15" = {
      remotePath = "machines/high-trust/github_read_token_2026-03-15";
      configChanges.nix.extraOptions = "!include $SECRET_PATH";
    };
  };

  secrets = commonSecrets // extraSecrets;
in
{
  imports = [
    inputs.secrets_manager.nixosModules.agent
    (inputs.secrets_manager.lib.applyChanges secrets)
  ];

  ringofstorms.secrets.agent = {
    enable = true;
    inherit secretsDir secrets;
    server = "https://secrets.joshuabell.xyz";
    machineKeyPath = "/machine-key.json";

    zitadel = {
      issuer = "https://sso.joshuabell.xyz";
      projectId = "344379162166820867";
    };
  };
}
