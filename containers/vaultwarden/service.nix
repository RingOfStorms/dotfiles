# vaultwarden (vault.joshuabell.xyz). SQLite, single-user vault.
{
  name = "vaultwarden";
  kind = "nixos";
  description = "vaultwarden password manager (vault.joshuabell.xyz)";

  persist = {
    data = "/var/lib/vaultwarden"; # db.sqlite3, rsa_key, attachments, sends
    backups = "/var/lib/backups/vaultwarden"; # nightly backup-vaultwarden copy
    nixos = "/var/lib/nixos";
  };

  # Consistent SQLite copy next to the live db, so a restore never depends
  # on the WAL state of the stopped copy.
  backup.hooks.pre = "systemctl start backup-vaultwarden.service";

  # sec-agent grant on the host (bound read-only in flake.nix); cnt deploy
  # and cnt move refuse a target host that lacks it.
  secrets = [ "vaultwarden_env_2026-03-15" ];

  net = {
    private = true;
    index = 5;
  };

  routes.web = {
    group = "Identity & Security";
    icon = "https://api.iconify.design/mdi/shield-lock.svg?color=%237fb0e8";
    port = 8222;
    name = "vault";
    exposure = "public";
    auth = "native";
    maxBody = "525m";
    # Strict per-IP rate limit + fail2ban on o002 (lib.nix edgeLogin).
    # connect/token also serves token refreshes (about one per client per
    # hour); the burst covers them.
    loginPaths = [
      "/identity/connect/token"
      "/identity/accounts/prelogin"
      "/api/accounts/prelogin"
      "/api/accounts/password-hint"
      "/api/two-factor/send-email-login"
      "/admin"
    ];
  };
}
