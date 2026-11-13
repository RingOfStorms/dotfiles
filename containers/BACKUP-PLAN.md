# Backup rollout closeout

The implemented architecture, commands, data selection, retention and recovery guidance now belong in [README.md](README.md). [INVENTORY.md](INVENTORY.md) records data locations, historical copies and coverage caveats. This file is only the remaining rollout checklist; remove it after these items are completed or explicitly deferred and the lasting decisions are in those documents.

## Implemented and observed

- P1–P5: h004 target/pusher, per-subject credentials, runtime policy/UI, client cutover, media extra paths, h001 archives and fleet-edge host subject are deployed.
- The Nov 13 morning B2 run succeeded: all 15 subjects enabled at that run passed retention-set completeness and sampled data-read checks. Immich verified at 07:45 CST; the full job ended at 07:49 CST. This is not a full restore or a read of every stored byte.
- Minecraft's first B2 copy and sampled verification succeeded on Nov 13; `complete=true`, no missing snapshots, 3,667,830,622 stored bytes. The full follow-on job ended at 15:26 CST; all 16 enabled offsite subjects report complete.
- h001's legacy restic timer and service were removed live on Nov 13; the current per-subject `fleet-backup.timer` remains active.
- Sec was updated with the legacy registry entry removed. Metadata-only queries confirmed zero active fields and grants for `machines/high-trust/restic_h001_env_2026-10-01`; encrypted historical versions/tombstones remain. Declarative removal does not erase that history or revoke a Backblaze key.
- The old hydrated credential was explicitly removed on h001 and h003. It was absent on h004, h005 and o002. Lio still needs privileged cleanup; gp3, juni and oren were unreachable during the audit.

## Decisions superseding the original plan

- **No fixed waiting period:** the user waived the seven-day retirement wait on Nov 13. Do not impose the earlier seven-day/three-day timetable as a remaining requirement.
- **Legacy B2 deletion stays last:** first prove recovery, including the proposed h001-to-h003 service migrations. No service has been selected or moved as part of this cleanup.
- `litellm`, `llm-router`, `searx`, `hello-nixos` and `hello-podman` have disposable state and no future backup requirement. Their `backup.enable = false` declarations do not delete existing snapshots. Restore-based `cnt move` requires backups; these services can instead be redeployed/re-authenticated without preserving state, or backups can be deliberately enabled for a migration.
- `h001-archives` remains local-only: h001 originals plus h004 backup. Stopping the old job does not delete its existing B2 snapshots; deleting legacy B2 later removes its offsite coverage.
- Minecraft is enabled offsite. Personal bulk-disk archives remain outside this rollout; no deletion of them or migration tarballs was authorized.
- **Do not equate a move with an independent restore:** current `cnt move` restores snapshot state but also transfers live PostgreSQL clusters from the stopped surviving source. A successful move does not demonstrate rebuilding PostgreSQL from B2 SQL dumps with h001 unavailable.

## P7 — Joe / LocalAI

This rollout is not enabled yet. Joe has no backup timer and h004 has no `svc-localai` repository.

- [ ] Choose the LocalAI data to preserve. Downloaded models/backends are generally replaceable, but `models/` may also hold custom YAML and voice packs. Separate or explicitly include custom data before excluding whole directories.
- [ ] Add narrow **Joe-only** Headscale permissions for the backup/authentication path. Live Headscale registration confirms Joe is `tag:lowtrust`; the current ACL denies traffic originating from that tag. Do not grant all low-trust nodes broad access to trusted hosts. Joe needs h004 rest-server (`100.64.0.17:8000`) and the h005 policy/credential API. h005's firewall separately drops low-trust HTTPS, and Joe disables tailnet DNS: add the deliberate API exception and hostname resolution while preserving TLS and the intended DNS isolation. SSO can use its existing public endpoint; prove the actual client path before adding more ACLs.
- [ ] Set `ringofstorms.backup.target.lowTrustClients = [ "joe" ]` on h004 and enable the backup client on Joe. The target firewall and Headscale ACL are separate gates.
- [ ] Ensure the subject resolves to h004; the existing machine identity requests only its own subject's credentials from fleet-edge. No fleet-wide B2 key or new sec-managed subject secret is required.
- [ ] Initialize `svc-localai` explicitly as `restic`, deploy, and take the first backup. Confirm privateRepos rejects other subjects and append-only rejects deletion.
- [ ] Save a fresh fleet-edge credential export externally if subject credentials were newly generated.

### Low-trust provenance

Implemented and deployed on h005 and h004. `writtenBy: low` is a conservative history marker; absent means unknown, not high trust. It survives service/target moves, rollbacks, retirement, clears and unavailable stats. Target `written-by.json` is separate from measurements, so history does not invent a held repo or size. Live heartbeat/stats runs succeeded with `localai: low` and no LocalAI stats/repository. Both views showed the warning in the real-service loopback smoke after a Joe rollback and trusted-host placement; the live dashboard's sign-in boundary was preserved. Full Go checks plus affected race tests passed; generated target failure/missing-repo smoke passed.

## P6 — remaining credential retirement

The user confirms saved copies of `restic_h001_env_2026-10-01` and `restic_b2_h004_2026-11-11` outside sec. The latter is B2 object access, **not** the per-subject restic passwords.

- [ ] Save/confirm the latest fleet-edge `/backup/` **Export all** in the password manager, including `fleet-edge` itself. Preserve existing sec/Zitadel recovery keys and Backblaze account/MFA recovery material. Do not paste secrets into chat or commit them.
- [ ] Delete lio's stale `/var/lib/secrets_manager_hydrated/restic_h001_env_2026-10-01` with local sudo. Registry removal and sec-agent reload do not delete an already-hydrated file.
- [ ] Audit gp3, juni and oren when reachable; remove that exact stale hydrated file if present. Unreachable is not proof of absence.
- [ ] Revoke the **old legacy Backblaze application key**, not h004's new `svc-` pusher key. Removing the declarative secret does not revoke an external B2 key. Use Backblaze account access; do not assume a bucket-scoped pusher key has key-administration permissions.
- [ ] Retain usable legacy repository access until P6b: legacy repo URL/password and a read-only prefix-scoped key or account access to issue one. Do not rely on sec's encrypted orphan history as the only recovery mechanism.
- [ ] Deploy lio's changed backup declarations so `hello-podman` no longer gets scheduled backups. Local sudo is required; leave `PermitRootLogin = "no"` unchanged.

Lio's coverage-only closure was built successfully without changing its lock file
and is protected from GC by `/home/josh/.cache/backup-closeout-lio-system`.
Run locally with sudo (the assistant cannot supply that password):

```sh
sudo nix-env -p /nix/var/nix/profiles/system --set /nix/store/61f4xfp6l5aj51xk4yxjjl8gvf0v8f93-nixos-system-lio-26.05.20261108.ac588ef
sudo /nix/store/61f4xfp6l5aj51xk4yxjjl8gvf0v8f93-nixos-system-lio-26.05.20261108.ac588ef/bin/switch-to-configuration switch
sudo rm -f -- /var/lib/secrets_manager_hydrated/restic_h001_env_2026-10-01
rm -- /home/josh/.cache/backup-closeout-lio-system
```

This closure includes the backup exclusions but predates the final provenance
client build. To include all current changes instead, rebuild from the working tree:
`nixos-rebuild switch --flake ./hosts/lio#lio --override-input containers
git+file:///home/josh/.config/nixos-config?dir=containers` with sudo.

## P6b — restore/move proof, then legacy B2 deletion

- [x] All 16 currently enabled offsite subjects, including Minecraft, report complete after the Nov 13 follow-on run. Recheck freshness before deletion; a sampled check is not a full restore.
- [ ] Select suitable services for h001-to-h003 migration. Check capability, available space, external binds, secrets, hooks and rollback before stopping anything. Bulk moves retain the source copy and may require a long pre-sync.
- [ ] Independently restore representative application state and PostgreSQL dumps from B2 to scratch, using the saved recovery credentials without relying on live h001 databases or fleet-edge availability. Verify application/database behavior, not only file listings.
- [ ] Verify the **actual legacy repository URL and object prefix**. `7f023d4a` in the old notes is not a verified deletion target. The saved legacy environment identifies the repository; the new pusher key is scoped to `svc-` and must remain untouched.
- [ ] Delete only the approved legacy repository data after proof succeeds, then retire its password/read-only access from the recovery record. Do not delete current `svc-*` repositories, original media, h001 archives or personal disk data.
- [ ] Confirm storage/cost reduction and that new nightly backup/copy jobs continue successfully.

## P8 — finish documentation consolidation

- [x] Consolidated README/host/recovery guidance, removed obsolete `ideas/restic_backups.md` after preserving useful context, checked local links, and redirected numbered historical pointers to permanent documentation.
- [x] Updated the dated inventory with current decisions and deployed provenance without overwriting historical measurements.
- [ ] Once P7, remaining credential cleanup and P6b are finished or explicitly deferred, remove this checklist and migrate any still-needed operational instructions into the permanent README. Do not delete the checklist while it is the only record of pending work.
