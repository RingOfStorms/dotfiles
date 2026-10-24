# Shared sec-agent configuration for hosts that have left secrets-bao.
#
# Host flakes pass the trust role and only their host-specific secrets. Keeping
# the fleet-wide definitions here means the SSH identity, GitHub/Forgejo key,
# GitHub read token, and headscale mapping cannot drift from one host to another.
{
  inputs,
  constants,
  role,
  # Fleet SSH identities (nix2nix root-to-every-host, nix2github,
  # nix2gitforgejo). Off on hosts that never initiate fleet SSH or git pushes
  # (o002, the public edge): a compromise there must not yield root on the
  # rest of the fleet.
  includeFleetSshKeys ? true,
  extraSecrets ? { },
  secretsDir ? "/var/lib/secrets_manager_hydrated",
}:
let
  lib = inputs.nixpkgs.lib;
  primaryUser = constants.host.primaryUser;
  group = if primaryUser == "root" then "root" else "users";

  # Derived from the fleet registry (hosts/fleet.nix `sshMatchBlockHosts`):
  # every registered host plus a `<name>_` variant where it has a direct IP
  # (lanIp/publicIp). This is exactly the set of HM ssh matchBlocks fleet
  # generates, so the nix2nix IdentityFile can't drift and retired hosts
  # (h002) drop out automatically.
  nix2nixMatchBlockHosts = (import ./fleet.nix).sshMatchBlockHosts;

  isHighTrust = role == "machines-hightrust";
  trustPath = if isHighTrust then "high-trust" else "low-trust";

  commonSecrets = {
    "headscale_auth_${if isHighTrust then "2026-03-15" else "lowtrust_2026-03-15"}" = {
      remotePath = "machines/${trustPath}/headscale_auth_${
        if isHighTrust then "2026-03-15" else "lowtrust_2026-03-15"
      }";
      softDepend = [ "tailscaled" ];
      # First boot: tailscaled-autoconnect runs (and fails) before this key is
      # fetched, and nothing retries it. Start it once the key lands. Only
      # fires when the file changes, so steady state is unaffected.
      hardDepend = [ "tailscaled-autoconnect" ];
      configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
    };
  }
  // lib.optionalAttrs (isHighTrust && includeFleetSshKeys) {
    "nix2nix_2026-03-15" = {
      remotePath = "machines/high-trust/nix2nix_2026-03-15";
      inherit group;
      owner = primaryUser;
      ensureNewline = true;
      hmChanges.programs.ssh.settings = builtins.listToAttrs (
        map (host: {
          name = host;
          value = {
            IdentityFile = "$SECRET_PATH";
          };
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
  }
  // lib.optionalAttrs isHighTrust {
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
