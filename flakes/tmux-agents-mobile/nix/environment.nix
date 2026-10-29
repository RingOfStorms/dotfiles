# Environment for the service, derived from `services.tmux-agents-mobile`.
# Shared by the platform modules so they cannot drift.
{ cfg, lib }:
let
  zitadel = cfg.zitadel;
in
{
  TAM_LISTEN = cfg.listen;
  TAM_HEALTH_LISTEN = cfg.healthListen;
  TAM_ROOTS = lib.concatStringsSep ":" cfg.roots;
  TAM_ZITADEL_ISSUER = zitadel.issuer;
  TAM_ZITADEL_PROJECT_ID = zitadel.projectId;
  TAM_ZITADEL_CLAIM = zitadel.claim;
  TAM_ZITADEL_CLIENT_ID = zitadel.clientId;
  TAM_ZITADEL_REDIRECT_URI = zitadel.redirectUri;
  TAM_ZITADEL_ROLE = zitadel.role;
}
// lib.optionalAttrs (cfg.sessionKeyFile != null) {
  TAM_SESSION_KEY_FILE = cfg.sessionKeyFile;
}
// cfg.extraEnvironment
