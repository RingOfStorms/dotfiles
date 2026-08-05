# sec agent config for oren — replaces secrets-bao.
#
# oren is the first host cut over from secrets-bao to sec. The agent
# renders into /var/lib/openbao-secrets (the legacy default dir) because
# secrets-bao is now disabled on this host — no conflict, and every
# existing consumer path (atuin secretFile, SSH IdentityFile) is
# unchanged.
#
# All 6 secrets come from the sec server at secrets.joshuabell.xyz.
# Access is via the device_high_trust role grant (same as openbao today).
{ inputs, constants, ... }:
let
  # Must match flakes/secrets-bao/flake.nix nix2nixMatchBlockHosts and
  # hosts/fleet.nix sshMatchBlockHosts.
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
in
{
  imports = [ inputs.secrets_manager.nixosModules.agent ];

  ringofstorms.secrets.agent = {
    enable = true;
    allowSharedSecretsDir = true; # secrets-bao is gone from oren

    server = "https://secrets.joshuabell.xyz";
    machineKeyPath = "/machine-key.json";

    zitadel = {
      issuer = "https://sso.joshuabell.xyz";
      projectId = "344379162166820867";
    };

    secrets = {
      # ── headscale auth key ───────────────────────────────────────
      "headscale_auth_2026-03-15" = {
        remotePath = "machines/high-trust/headscale_auth_2026-03-15";
        softDepend = [ "tailscaled" ];
        configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
      };

      # ── inter-machine SSH key ────────────────────────────────────
      "nix2nix_2026-03-15" = {
        remotePath = "machines/high-trust/nix2nix_2026-03-15";
        owner = "josh";
        group = "users";
        hmChanges.programs.ssh.settings = builtins.listToAttrs (
          map (host: {
            name = host;
            value = { IdentityFile = "$SECRET_PATH"; };
          }) nix2nixMatchBlockHosts
        );
      };

      # ── GitHub SSH key ───────────────────────────────────────────
      "nix2github_2026-03-15" = {
        remotePath = "machines/high-trust/nix2github_2026-03-15";
        owner = "josh";
        group = "users";
        hmChanges.programs.ssh.settings."github.com".IdentityFile = "$SECRET_PATH";
      };

      # ── Forgejo SSH key ──────────────────────────────────────────
      "nix2gitforgejo_2026-03-15" = {
        remotePath = "machines/high-trust/nix2gitforgejo_2026-03-15";
        owner = "josh";
        group = "users";
        hmChanges.programs.ssh.settings."git.joshuabell.xyz".IdentityFile = "$SECRET_PATH";
      };

      # ── GitHub read token (nix fetches) ──────────────────────────
      "github_read_token_2026-03-15" = {
        remotePath = "machines/high-trust/github_read_token_2026-03-15";
        configChanges.nix.extraOptions = "!include $SECRET_PATH";
      };

      # ── atuin sync key (per-host) ─────────────────────────────────
      # The atuin module reads this via secretFile in flake.nix.
      # The single `value` field holds the pre-formatted 3-line content
      # (user\npassword\nkey) that atuin-autologin parses with sed.
      "atuin-key-josh_2026-03-15" = {
        remotePath = "machines/high-trust/atuin-key-josh_2026-03-15";
        field = "value";
        owner = "josh";
        group = "users";
        mode = "0400";
        hardDepend = [ "atuin-autologin" ];
      };
    };
  };
}
