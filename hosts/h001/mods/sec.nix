# `sec` — the secrets manager that will replace OpenBao.
#
# During the migration this runs ALONGSIDE OpenBao on the same host. That
# is only safe because nothing is shared:
#
#   port        8300                       (openbao: 8200)
#   data        /var/lib/secrets_manager    (openbao: /var/lib/openbao)
#   hostname    secrets.joshuabell.xyz      (openbao: sec.joshuabell.xyz)
#   units       sec.service                 (openbao: openbao*.service)
#
# The `sec` CLI is deliberately NOT installed (installCli stays false):
# the secrets-bao module already puts a shell script named `sec` on PATH,
# and two different programs with one name is a footgun. The server does
# not need the binary on PATH — its unit calls an absolute store path.
# Flip installCli on once secrets-bao is gone from this host.
#
# NOTE the desired state below is intentionally NOT yet the full OpenBao
# registry. Phase 1 is "does the server run and serve"; the remaining
# paths get added as they are migrated, one at a time, so a mistake in
# this file cannot take out a secret that something depends on today.
{
  inputs,
  constants,
  fleet,
  ...
}:
let
  c = constants.services.sec;
  domain = fleet.global.domain;
in
{
  imports = [ inputs.secrets_manager.nixosModules.server ];

  ringofstorms.secrets.server = {
    enable = true;

    listen = "127.0.0.1:${toString c.port}";
    inherit (c) dataDir domain;

    # Reuse the wildcard cert nginx.nix already obtains. `secrets` is a
    # single label under joshuabell.xyz, so *.joshuabell.xyz covers it
    # and no extraDomainNames entry is needed.
    useACMEHost = domain;

    # The key is generated into dataDir on first start and then never
    # touched again. BACK IT UP. Without it every stored value is
    # permanently undecryptable — there is no recovery path.
    generateKey = true;

    # Declarative mode: Nix owns the key set. The server refuses runtime
    # key creation/deletion and grant mutation — only values may be
    # written through the UI. The reconciler prunes any key not declared
    # below (tombstoning it into secret_versions first). Flip this off
    # only if you want the database to be the sole source of truth.
    declarative = true;

    zitadel = {
      issuer = "https://${constants.services.zitadel.domain}";
      # Same Zitadel project the OpenBao JWT auth method binds to, so the
      # machine identities that exist today work here unchanged.
      projectId = "344379162166820867";
      claim = "flatRolesClaim";

      # Admin UI sign-in. The clientId is the Zitadel application's
      # client ID; the server refuses the OIDC flow while this is empty,
      # so a half-finished setup fails closed rather than accidentally
      # exposing an unauthenticated UI.
      clientId = "384856081475633155";
      redirectUri = "https://${c.domain}/ui/callback";
    };

    # Phase 1: one real path, to prove the round trip end to end without
    # touching anything OpenBao currently serves. Values start as
    # `TODO:replace_me` stubs and are filled in through the UI; the
    # reconciler never overwrites a value that is already set.
    #
    # Access is granted explicitly per key — no prefix matching. A
    # `role` grant binds to a Zitadel role claim value; a `sub` grant
    # binds to a specific machine identity's service-account userId.
    # The old `machines-hightrust` role (bound to `device_high_trust`)
    # could read everything under machines/high-trust/; the new model
    # requires an explicit grant on each key, so this one grants read to
    # any caller carrying the `device_high_trust` role claim.
    secrets = {
      "machines/high-trust/nix2nix_2026-03-15" = {
        fields = [ "value" ];
        description = "Inter-machine SSH key. Mirror of the OpenBao entry — NOT yet consumed from here.";
        access = [
          { type = "role"; value = "device_high_trust"; }
        ];
      };
    };
  };
}
