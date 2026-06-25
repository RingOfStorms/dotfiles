# Oracle Cloud hosts

NixOS on Oracle Cloud **Ampere A1 (aarch64)** free-tier VMs, installed via
**nixos-anywhere + disko** (no ISO/image upload — not free-tier eligible).
This permanently fixes the old `nixos-infect` problem of a 200 MB `/boot` that
forced kernel-pinning and manual generation pruning. The new layout is
bcachefs with a 3 GB ESP, plus impermanence (boot-time root reset).

- `bootstrap/` — reusable template host. Copy it to `hosts/oracle/<name>/`
  to onboard a new instance.
- `o001/` — original gateway (nixos-infect, tiny `/boot`). Being decommissioned.
- `o002/` — gateway rebuild on the clean bcachefs + impermanence stack.

---

## Free-tier compute budget

Oracle "Always Free" Ampere A1 gives a total of **4 OCPU / 24 GB RAM** and
**200 GB block storage**, splittable across instances. Current split:

| Instance | OCPU | RAM   | Boot vol | Notes                          |
|----------|------|-------|----------|--------------------------------|
| o002     | 2    | 12 GB | 70 GB    | gateway rebuild                |
| (free)   | 2    | 12 GB | ~130 GB  | available for a 2nd instance   |

So a second instance can be **2 OCPU / 12 GB** with up to ~130 GB boot volume.

---

## Onboarding a new Oracle instance

### 1. Create the VM (Oracle web console)

- **Shape:** `VM.Standard.A1.Flex`, set OCPU + RAM from the budget above.
- **Image:** Canonical **Ubuntu** (Minimal aarch64). We take it over with
  nixos-anywhere; its partitioning is discarded.
- **Boot volume:** size from the budget (o002 used 70 GB → disko carves 3 GB
  ESP + 8 GB swap + rest bcachefs).
- **SSH key:** add the fleet `nix2nix_2026-03-15` **public** key at create time
  (so we can SSH in as `ubuntu` immediately):
  `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0aeQA4617YMbhPGkCR3+NkyKppHca1anyv7Y7HxQcr nix2nix_2026-03-15`
- Note the assigned **public IP**.

### 2. Open the Oracle security list (easy to forget!)

This is **separate** from the NixOS firewall — without it, ports are blocked at
the cloud level even if the OS allows them.

`Networking > Virtual Cloud Networks > <vcn> > <subnet> > <security list>`
→ add ingress rules (mirroring how 22 is already open):

- TCP **22** (SSH — usually already open)
- TCP **80, 443** (web / ACME) — for a gateway
- TCP **3032** (git ssh stream) — if hosting the git proxy
- (We use **public DERP**, so no UDP 3478 is needed.)

### 3. Create the host config from the template

```sh
cd hosts/oracle
cp -r bootstrap <name>          # e.g. o003
$EDITOR <name>/_constants.nix   # set host.name, publicIp
```

In `<name>/flake.nix`, **set `enableImpermanence = false` for the first
install** (see the gotcha below).

Add the host to the registry so `ssh <name>` works and secrets wire up:

- `hosts/fleet.nix` → add an entry under `hosts` (user=root, publicIp, trust,
  flakePath, and overlayIp once it joins).
- `flakes/secrets-bao/flake.nix` → add `"<name>" "<name>_"` to
  `nix2nixMatchBlockHosts`.

Commit + push (the host flakes pull `common`/`impermanence`/`secrets-bao` from
the git remote, so changes must be pushed before installing):

```sh
git add -A && git commit -m "oracle: onboard <name>" && git push
```

### 4. First install via nixos-anywhere (impermanence OFF)

The build runs on lio (aarch64 via binfmt; `extra-platforms = aarch64-linux`
must be set in lio's nix config — it is). Make the nix2nix key readable:

```sh
sudo cp /var/lib/openbao-secrets/nix2nix_2026-03-15 /tmp/onboardkey
sudo chown $USER /tmp/onboardkey && chmod 600 /tmp/onboardkey

cd hosts/oracle/<name>
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<name> \
  --build-on local \
  --target-host ubuntu@<public-ip> \
  --ssh-option IdentitiesOnly=yes \
  --ssh-option IdentityFile=/tmp/onboardkey
```

Notes / gotchas hit during o002:
- Do **not** use `SSH_KEY=...` env — it doesn't propagate to the internal
  `ssh-copy-id` step and loops forever. Pass `--ssh-option IdentityFile=...`.
- Oracle accepts only the key you added at create time; `IdentitiesOnly=yes`
  avoids offering the wrong key.
- It kexecs, runs disko (wipes /dev/sda → 3 GB ESP + 8 GB swap + bcachefs),
  installs, and reboots. Host key changes after install:
  `ssh-keygen -R <public-ip>`.
- Disko's GPT partition labels are `disk-main-ESP`, `disk-main-swap`,
  `disk-main-primary` (referenced by the impermanence `disk` paths).

### 5. Turn on impermanence (the safe sequence)

**Why not just install with impermanence on?** The impermanence root-reset
wipes `@root` on first boot. On a fresh install `/persist` is empty, so the
first reset destroys the just-installed ssh host keys / machine-id with nothing
to restore → the headless box never comes back. `nixos-rebuild` avoids this
because activation populates `/persist` **before** the next (first) reset.

So, after the box is up on the plain bcachefs root:

```sh
# seed the persistent initrd ssh host key (for the initrd-ssh recovery aid)
ssh <name> 'mkdir -p /persist/initrd && \
  ssh-keygen -t ed25519 -N "" -f /persist/initrd/ssh_host_ed25519_key -C "<name>-initrd" && \
  chmod 600 /persist/initrd/ssh_host_ed25519_key'

# flip the toggle and deploy (activation seeds /persist), THEN reboot
$EDITOR hosts/oracle/<name>/flake.nix   # enableImpermanence = true
git add -A && git commit -m "oracle: <name> enable impermanence" && git push

cd hosts/oracle/<name>
NIX_SSHOPTS="-i /tmp/onboardkey -o IdentitiesOnly=yes" \
  nixos-rebuild switch --flake .#<name> --target-host root@<public-ip> --build-host localhost

ssh <name> 'systemctl reboot'
```

Verify after reboot: `ssh <name>` works, `/.snapshots/old_roots/` has a
snapshot, `/persist` survives, machine-id is stable.

### 6. secrets-bao bootstrap (Zitadel machine identity)

The box can't fetch secrets (or join the tailnet) until it has a Zitadel
machine key. In `https://sso.joshuabell.xyz` (admin):

1. **Users → Machine Users → + New**: name `<name>`, **Access Token Type: JWT**.
2. **Projects → (OpenBao-trusted project) → Authorizations**: grant the new
   user the **`machines-hightrust`** role.
3. **Keys → + New → JSON**, download. This is `machine-key.json`.

Seed it (impermanence binds `/persist/machine-key.json` → `/machine-key.json`):

```sh
scp ~/Downloads/<KEY>.json <name>:/tmp/mk.json
ssh <name> '
  install -m400 -oroot -groot /tmp/mk.json /persist/machine-key.json && rm /tmp/mk.json &&
  touch /machine-key.json && mount --bind /persist/machine-key.json /machine-key.json
'
# kick the pipeline
ssh <name> '
  systemctl start zitadel-mint-jwt.service && systemctl start vault-agent.service; sleep 5
  ls /run/openbao/zitadel.jwt; ls /var/lib/openbao-secrets/
'
# join the tailnet
ssh <name> 'systemctl restart tailscaled-autoconnect.service; sleep 5; tailscale ip -4'
```

Record the assigned overlay IP in `hosts/fleet.nix` and the host
`_constants.nix`. Rebuild lio (`nixos-rebuild switch`) so `ssh <name>` resolves
via MagicDNS.

### 7. Layer services on top

Add service modules (nginx, postgres, vaultwarden, atuin, …) and their data
dirs to the impermanence persist set + `ringofstorms.backup.paths`. Note:
`/machine-key.json` is deliberately **never** backed up (re-seed per host).

---

## Serial console (for headless boot debugging)

If a box won't boot (e.g. an impermanence/initrd issue), use the OCI serial
console. The web UI hides it; the CLI is reliable:

```sh
# one-time: configure OCI CLI auth (oci setup config + upload API public key)
# Oracle's serial console requires an RSA key (rejects ed25519):
ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/oci_console_rsa

INST=<instance-ocid>
nix run nixpkgs#oci-cli -- compute instance-console-connection create \
  --instance-id "$INST" --ssh-public-key-file ~/.ssh/oci_console_rsa.pub

# get the connection-string, then connect (re-enable ssh-rsa for the old host key):
ICC=<instance-console-connection-ocid>
ssh -F /dev/null -o ControlMaster=no -o ControlPath=none \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -i ~/.ssh/oci_console_rsa \
  -o ProxyCommand="ssh -F /dev/null -i ~/.ssh/oci_console_rsa -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -W %h:%p -p 443 $ICC@instance-console.us-chicago-1.oci.oraclecloud.com" \
  $INST
```

The initrd-ssh aid (`debug-boot.nix`) also lets you `ssh root@<ip>` straight
into the initrd if a boot hangs before pivot.

---

## Reference: what the bootstrap template sets up

- **Bootloader:** GRUB installed as removable (`efiInstallAsRemovable`) to the
  ESP fallback path — confirmed booting on Oracle Ampere UEFI.
- **Disk (disko):** GPT, 3 GB FAT32 ESP, 8 GB swap, bcachefs with subvolumes
  `@root` (/), `@nix`, `@persist`, `@snapshots`. Unencrypted (headless box).
- **Impermanence:** boot-time `@root` snapshot+wipe; `/persist` holds ssh host
  keys, machine-id, openbao-secrets, tailscale state, `/machine-key.json`.
- **Modules:** essentials, git, hardening, nix_options, tailnet, zsh, backup
  (rsync push to h002), secrets-bao (machines-hightrust), cloudUser auth.
- **nixpkgs:** nixos-26.05, stateVersion 26.05.
