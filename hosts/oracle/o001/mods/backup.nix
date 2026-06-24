# o001 backup config: push critical gateway state to the h002 NAS.
#
# Uses the reusable ringofstorms.backup module (rsync push over the
# tailnet via nix2nix). Database dumps are handled per-host:
# services.postgresqlBackup is enabled in mods/postgresql.nix and its
# dump directory (/var/backup/postgresql) is included in paths below.
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
  };
}
