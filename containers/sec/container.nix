# Guest config: ringofstorms.secrets.server copied from hosts/h001/mods/sec.nix.
# domain = null: the module's nginx vhost is skipped; the host's nginx vhost
# lives in service.nix.
{ secrets_manager, ... }:
{
  imports = [ secrets_manager.nixosModules.server ];
  system.stateVersion = "25.05";

  ringofstorms.secrets.server = {
    enable = true;
    installCli = true;
    listen = "127.0.0.1:8300";
    dataDir = "/var/lib/secrets_manager";
    domain = null;
    # Only ever generates on an empty dataDir; the copied db.key is kept.
    generateKey = true;
    declarative = true;

    zitadel = {
      issuer = "https://sso.joshuabell.xyz";
      projectId = "344379162166820867";
      claim = "flatRolesClaim";
      clientId = "384856081475633155";
      redirectUri = "https://secrets.joshuabell.xyz/ui/callback";
    };

    secrets = import ./registry.nix;
  };
}
