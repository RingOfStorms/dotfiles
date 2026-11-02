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
  backupHook = "systemctl start backup-vaultwarden.service";

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
  };
}
