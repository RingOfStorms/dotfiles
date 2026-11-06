# Backup subjects and their secret grants (containers/BACKUP-PLAN.md §2.7).
# One registry key machines/backup/restic_svc-<name>_<date> per subject,
# sub-granted to its client hosts plus every target. Client hosts are derived:
#   [ placed.<n> ] ++ [ pendingMove.<n> ]  (nulls/absent dropped)
# placed.<n> mirrors the live placement registry (h005 fleet-edge placements);
# null = unbound/reserved, no client host. Never list hosts a subject "may
# run on".
#
# Move sequence (cnt move needs BOTH grants: movePreflightSource requires the
# source credential through prepare and the final backup; movePreflightTarget
# requires the destination's):
#   1. set pendingMove.<n> = "<dest>"; deploy sec and the destination;
#   2. cnt move <n> <dest>;
#   3. after the move commits: placed.<n> = "<dest>", drop pendingMove.<n>,
#      deploy sec, then delete the hydrated copy on the source.
# The source grant is revoked only after the move commits.
let
  date = "2026-11-05";
  subs = {
    h001 = "354449452515196931";
    lio = "344412093056811011";
    h003 = "364267072236027907";
    h004 = "394968645089886211";
  };
  targets = [ "h004" ];
  placed = {
    arr = "h001";
    atuin = "h001";
    dawarich = "h001";
    forgejo = "h001";
    hello-nixos = "h003";
    hello-podman = null; # unbound in placement registry
    immich = "h001";
    life = "h001";
    litellm = "h001";
    minecraft = null; # unbound in placement registry
    open-webui = "h001";
    opengist = "h001";
    paperless = "h001";
    puzzles = "h001";
    searx = "h001";
    sec = "h001";
    trilium = "h001";
    vaultwarden = "h001";
    zitadel = "h001";
  };
  # dest of an in-flight move; absent normally
  pendingMove = { };
  # client hosts per subject, derived (see header)
  clientHostsOf =
    placed: pendingMove:
    builtins.mapAttrs (
      n: p:
      builtins.filter (h: h != null) [
        p
        (pendingMove.${n} or null)
      ]
    ) placed;
  # schema checks; returns a list of error strings ([] = ok)
  check =
    {
      known,
      placed,
      pendingMove,
    }:
    let
      ch = clientHostsOf placed pendingMove;
      names = builtins.attrNames placed;
    in
    map (n: "placed.${n}: not null or a known host") (
      builtins.filter (n: placed.${n} != null && !(builtins.elem placed.${n} known)) names
    )
    ++ builtins.concatMap (
      n:
      let
        d = pendingMove.${n};
      in
      (if placed ? ${n} then [ ] else [ "pendingMove.${n}: unknown subject" ])
      ++ (if builtins.elem d known then [ ] else [ "pendingMove.${n}: unknown host" ])
      ++ (if (placed.${n} or null) == null then [ "pendingMove.${n}: subject not placed" ] else [ ])
      ++ (if (placed.${n} or null) == d then [ "pendingMove.${n}: same as placed" ] else [ ])
    ) (builtins.attrNames pendingMove)
    ++ map (n: "${n}: bad client host count") (
      builtins.filter (
        n:
        let
          l = builtins.length ch.${n};
        in
        l > 2 || (l == 2 && !(pendingMove ? ${n}))
      ) names
    );
  hosts = clientHostsOf placed pendingMove;
  knownHosts = builtins.attrNames subs;
in
rec {
  inherit
    date
    subs
    targets
    placed
    pendingMove
    hosts
    knownHosts
    clientHostsOf
    check
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
