# Backup subjects and their secret grants (containers/BACKUP-PLAN.md §2.7).
# One registry key machines/backup/restic_svc-<name>_<date> per subject,
# sub-granted to the hosts listed here (where the subject may be placed) plus
# every target. Consumed by sec/registry.nix, hosts/*/sec-agent.nix and the
# target's subjectCredentials. Adding a host here is the reviewed registry
# change a `cnt move` needs first.
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
    hello-nixos = [
      "h001"
      "lio"
      "h003"
    ];
    hello-podman = [
      "h001"
      "lio"
    ];
    immich = h001;
    life = h001;
    litellm = h001;
    minecraft = [
      "h001"
      "h003"
    ];
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
