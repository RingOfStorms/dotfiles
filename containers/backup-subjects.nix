# Backup subjects and their secret grants (containers/BACKUP-PLAN.md §2.7).
# One registry key machines/backup/restic_svc-<name>_<date> per subject,
# sub-granted to exactly the one host the live placement registry (h005
# fleet-edge placements) binds it to, plus every target. Never list hosts a
# subject "may run on"; unbound/reserved subjects get no client host. A move
# destination grant is a separate reviewed change made before `cnt move`.
let
  date = "2026-11-05";
  subs = {
    h001 = "354449452515196931";
    lio = "344412093056811011";
    h003 = "364267072236027907";
    h004 = "394968645089886211";
  };
  targets = [ "h004" ];
  h001 = [ "h001" ];
  hosts = {
    arr = h001;
    atuin = h001;
    dawarich = h001;
    forgejo = h001;
    hello-nixos = [ "h003" ];
    hello-podman = [ ]; # unbound in placement registry
    immich = h001;
    life = h001;
    litellm = h001;
    minecraft = [ ]; # unbound in placement registry
    open-webui = h001;
    opengist = h001;
    paperless = h001;
    puzzles = h001;
    searx = h001;
    sec = h001;
    trilium = h001;
    vaultwarden = h001;
    zitadel = h001;
  };
in
rec {
  inherit
    date
    subs
    targets
    hosts
    ;
  keyName = n: "restic_svc-${n}_${date}";
  remotePath = n: "machines/backup/${keyName n}";
  hydrated = n: "/var/lib/secrets_manager_hydrated/${keyName n}";
  # sec-agent extraSecrets for one client host
  clientSecrets =
    host:
    builtins.listToAttrs (
      map (n: {
        name = keyName n;
        value = {
          remotePath = remotePath n;
          field = "value";
          mode = "0400";
          configChanges.ringofstorms.backup.client.credentials.${n} = "$SECRET_PATH";
        };
      }) (builtins.filter (n: builtins.elem host hosts.${n}) (builtins.attrNames hosts))
    );
  # sec-agent extraSecrets for a target
  targetSecrets = builtins.listToAttrs (
    map (n: {
      name = keyName n;
      value = {
        remotePath = remotePath n;
        field = "value";
        mode = "0400";
        hardDepend = [ "render-htpasswd" ];
      };
    }) (builtins.attrNames hosts)
  );
  subjectCredentials = builtins.listToAttrs (
    map (n: {
      name = "svc-${n}";
      value = hydrated n;
    }) (builtins.attrNames hosts)
  );
  registry = builtins.listToAttrs (
    map (n: {
      name = remotePath n;
      value = {
        fields = [ "value" ];
        description = "Backup subject svc-${n}: RESTIC_PASSWORD, RESTIC_REST_USERNAME=svc-${n}, RESTIC_REST_PASSWORD.";
        access = map (h: {
          type = "sub";
          value = subs.${h};
        }) (hosts.${n} ++ targets);
      };
    }) (builtins.attrNames hosts)
  );
}
