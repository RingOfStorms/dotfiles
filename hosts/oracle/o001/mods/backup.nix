# o001 backup config: push critical gateway state to the h002 NAS.
#
# Uses the reusable ringofstorms.backup module (rsync push over the
# tailnet via nix2nix). postgresqlBackup is already enabled in
# mods/postgresql.nix (single source of truth), so we leave
# postgresBackup = false here and just include its dump directory
# (/var/backup/postgresql) in the rsync paths.
{ ... }:
{
  ringofstorms.backup = {
    enable = true;
    paths = [
      "/var/lib/vaultwarden"    # CRITICAL: password vault (uid/gid 114)
      "/var/lib/acme"           # TLS certs for ~25 domains
      "/machine-key.json"       # openbao/Zitadel bootstrap identity (irreplaceable)
      "/var/backup/postgresql"  # atuin DB dumps (postgresqlBackup, enabled in mods/postgresql.nix)
    ];
    postgresBackup = false; # postgresqlBackup is managed in mods/postgresql.nix
  };
}
