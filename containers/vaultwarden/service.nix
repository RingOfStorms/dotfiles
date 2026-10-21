# vaultwarden (vault.joshuabell.xyz). SQLite, single-user vault.
# Was a private-network nixos container in hosts/h001/containers/vaultwarden.nix;
# data copied 1:1 (uid/gid 114 kept inside the container).
{
  name = "vaultwarden";
  kind = "nixos";
  description = "vaultwarden password manager (vault.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/vaultwarden"; # db.sqlite3, rsa_key, attachments, sends
    backups = "/var/lib/backups/vaultwarden"; # nightly backup-vaultwarden copy
    nixos = "/var/lib/nixos";
  };

  # Consistent SQLite copy next to the live db, so a restore never depends
  # on the WAL state of the stopped copy.
  backupHook = "systemctl start backup-vaultwarden.service";

  # vaultwarden listens on 127.0.0.1:8222 (host network). o002 terminates TLS
  # for the public name and proxies to h001:80 over the tailnet.
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
