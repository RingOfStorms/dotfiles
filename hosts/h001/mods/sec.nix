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

    zitadel = {
      issuer = "https://${constants.services.zitadel.domain}";
      # Same Zitadel project the OpenBao JWT auth method binds to, so the
      # machine identities that exist today work here unchanged.
      projectId = "344379162166820867";
      claim = "flatRolesClaim";

      # Admin UI sign-in stays OFF until the redirect URI below is
      # registered in Zitadel. Set clientId to the Zitadel application's
      # client ID to switch it on — the server refuses the OIDC flow while
      # this is empty, so a half-finished setup fails closed rather than
      # accidentally exposing an unauthenticated UI.
      clientId = "";
      redirectUri = "https://${c.domain}/ui/callback";
    };

    # Mirrors the OpenBao policies in mods/openbao/openbao-config.nix.
    # Prefix matching, not a policy language: `read = [ "" ]` is everything.
    roles = {
      machines-hightrust = {
        boundClaim = "device_high_trust";
        read = [ "machines/high-trust/" "machines/low-trust/" ];
      };
      machines-lowtrust = {
        boundClaim = "device_low_trust";
        read = [ "machines/low-trust/" ];
      };
      host-h003 = {
        boundClaim = "device_high_trust";
        read = [
          "machines/high-trust/"
          "machines/low-trust/"
          "machines/by-host/h003/"
        ];
      };
      host-gp3 = {
        boundClaim = "device_low_trust";
        read = [ "machines/low-trust/" "machines/by-host/gp3/" ];
      };

      # The only role permitted to write, and even then only to paths
      # whose row already exists — the module asserts this.
      #
      # The attribute name `admin` is sec's own role (hardcoded as
      # ADMIN_ROLE; do not rename it). `boundClaim` is the Zitadel role
      # that grants it — the existing `admin` role in the project below,
      # so no new Zitadel role has to be created. Anyone holding that
      # role in project 344379162166820867 can read and write every
      # secret here.
      admin = {
        boundClaim = "admin";
        read = [ "" ];
        write = [ "" ];
      };
    };

    # Phase 1: one real path, to prove the round trip end to end without
    # touching anything OpenBao currently serves. Values start as
    # `TODO:replace_me` stubs and are filled in through the UI; the
    # reconciler never overwrites a value that is already set.
    secrets = {
      "machines/high-trust/nix2nix_2026-03-15" = {
        fields = [ "value" ];
        description = "Inter-machine SSH key. Mirror of the OpenBao entry — NOT yet consumed from here.";
      };
    };

    # Empty on purpose. A prefix listed here is one the reconciler OWNS:
    # any row under it that stops being declared above is tombstoned into
    # secret_versions and deleted. With the registry still partial, an
    # entry here would delete real data on the next rebuild. Add prefixes
    # only once every path beneath them is declared.
    managedPrefixes = [ ];
  };
}
