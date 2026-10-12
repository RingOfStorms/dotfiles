# NixOS Install with Disko + bcachefs Impermanence

Minimal steps to get a new machine from zero to a working NixOS host with
encrypted bcachefs, impermanence, and sec-agent secrets.

> **Hosts on sec-agent** (`hosts/sec-agent.nix`, i.e. every current host):
> The legacy Step 7 documents the retired secrets-bao/OpenBao flow. Use
> [Step 7 (sec-agent)](#step-7-sec-agent-first-boot) instead.

## Gotchas (learned the hard way)

- **Use Ethernet on the target.** Wi-Fi makes the closure copy (several GB)
  painfully slow.
- **Quote flake refs in zsh.** `nixos-rebuild build --flake .#gp3` fails with
  `zsh: no matches found` because `#` is a glob char. Write `'.#gp3'`.
- **Never `nix-copy-closure` to the live ISO.** Its `/nix/store` is an ~8G
  tmpfs, so it fills up with `No space left on device`. Copy into `/mnt`
  (Step 6).
- **`nix copy` needs `--no-check-sigs`.** Locally built paths are unsigned,
  and the ISO rejects them with `lacks a signature by a trusted key`.
- **Rebooting the installer loses everything** except what's on the disk.
  Re-unlock and re-mount (Step 3) before copying again.
- **`bcachefs unlock` over SSH, then `mount` returns `ENOKEY`.** The key goes
  into root's *user* keyring, which a different SSH/console session can't see.
  Run `keyctl link @u @s` in the session that mounts, or unlock and mount in
  the same session.
- **Disko reuses the bcachefs UUID.** The boot (vfat) and swap UUIDs change on
  re-format, but the primary bcachefs UUID can come back identical, because
  disko derives it from the filesystem name. Re-read all three with `lsblk -f`
  and don't assume the format failed.
- **Tailscale may not join on first boot.** `tailscaled-autoconnect` can run
  before sec-agent has fetched the headscale key, and it isn't retried. See
  Step 7 (sec-agent).
- **Headscale runs on o002**, not h001.

## Prerequisites

- Network access (Ethernet recommended, or `nmtui` for Wi-Fi)
- Your host config already committed in the dotfiles repo under `hosts/<name>/`
- A USB stick flashed with a **custom NixOS ISO** that includes bcachefs kernel
  support (neither the stable nor unstable stock ISOs include it)

### Building the ISO

From your workstation, build the installer ISO from this directory's flake:

```sh
# Stable channel (nixos-26.05):
nix build "./utilities/nixos-install-disko#iso-stable"

# Unstable channel:
nix build "./utilities/nixos-install-disko#iso-unstable"
```

The ISO will be at `result/iso/nixos-*.iso`.

### Flashing to USB

```sh
DEVICE=/dev/sdX  # double-check with lsblk!
ISO=$(realpath result/iso/nixos-*.iso)  # dd will not expand a glob inside if=
sudo dd if="$ISO" of="$DEVICE" bs=4M status=progress oflag=sync
```

The ISO includes bcachefs kernel + userspace tools, flakes enabled, SSH with
password auth, zsh, starship, neovim, and parted. Default password for both
`nixos` and `root` is `password`.

## Step 1: Boot the ISO & SSH In

Boot the target machine from the USB.

```sh
ip a
```

From your workstation, SSH in:

```sh
IP=10.12.14.125
ssh root@$IP -i /var/lib/secrets_manager_hydrated/nix2nix_2026-03-15
```

Flakes and bcachefs are already enabled on the ISO -- no setup needed.

## Step 2: Partition & Format

Pick **one** of the two approaches below. Disko is the quick path for simple
single-drive machines. For multi-drive arrays or unusual layouts, use the manual
approach.

```sh
lsblk
```

### Step 2a: Disko (single-drive)

Best for typical desktops/laptops with one NVMe or SSD. The ISO includes a
`disko_format` command with disko and the bcachefs partition config pre-bundled.

It creates:

- **Partition 1**: EFI System Partition (FAT32, 3GB)
- **Partition 2**: Swap (configurable, default 8G)
- **Partition 3**: bcachefs (rest of disk, optionally encrypted)
  - Subvolumes: `@root`, `@nix`, `@snapshots`, `@persist`

Identify the target disk and swap size:

```sh
lsblk
DISK=/dev/nvme0n1  # or /dev/sda, etc.
SWAP=16G           # swap partition size. NOT GB use G only
```

#### Encrypted (recommended)

```sh
# Write your disk encryption passphrase to a temp file
sudo $EDITOR /tmp/bcachefs.key

disko_format "$DISK" "$SWAP" --encrypted

# Clean up the key file
rm /tmp/bcachefs.key
```

#### Unencrypted

```sh
disko_format "$DISK" "$SWAP"
```

Disko may or may not mount the subvolumes correctly. Check with `mount | grep mnt`
and proceed to Step 3 to verify/fix the mounts.

### Step 2b: Manual partitioning (multi-drive / custom layouts)

For machines with multi-disk arrays, mixed filesystems, or other layouts that
don't fit the single-drive disko template (e.g. h002's 5-disk bcachefs array
with replication).

#### 1. Partition the boot drive

```sh
DISK=/dev/nvme0n1  # or /dev/sda, etc.

# Create GPT table
parted -s "$DISK" mklabel gpt

# EFI System Partition (3GB)
parted -s "$DISK" mkpart ESP fat32 1MiB 5GiB
parted -s "$DISK" set 1 esp on
mkfs.fat -F32 "${DISK}p1"

# Swap (adjust size as needed) (16GB)
parted -s "$DISK" mkpart swap linux-swap 5GiB 21GiB
mkswap "${DISK}p2"
swapon "${DISK}p2"

# Root partition (rest of disk)
parted -s "$DISK" mkpart primary 17GiB 100%
```

#### 2. Format bcachefs

Single-drive with encryption and subvolumes (impermanence):

```sh
echo -n 'your-passphrase' > /tmp/bcachefs.key
bcachefs format --encrypted --passphrase_file=/tmp/bcachefs.key \
  "${DISK}p3"
rm /tmp/bcachefs.key
```

Multi-drive array (e.g. replicated data pool, no encryption):

```sh
bcachefs format \
  --compression=zstd \
  --replicas=2 \
  /dev/sda /dev/sdb /dev/sdc /dev/sde /dev/sdf
```

#### 3. Unlock (if encrypted) and create subvolumes

```sh
# Unlock
bcachefs unlock "${DISK}p3"

# Mount
mount -t bcachefs "${DISK}p3" /mnt

# Create impermanence subvolumes
bcachefs subvolume create /mnt/@root
bcachefs subvolume create /mnt/@nix
bcachefs subvolume create /mnt/@persist
bcachefs subvolume create /mnt/@snapshots

umount /mnt
```

Skip the subvolumes if impermanence is not being used (e.g. a data-only array).

### Step 3: Mount Everything Under /mnt

Whether you used disko or manual partitioning, verify the mounts are correct
before proceeding. If disko already mounted everything, check with:

```sh
mount | grep /mnt
```

If the subvolumes are not mounted (or you used manual partitioning), mount them
now. Set the partition variables to match your layout:

```sh
# set this if not already set from Step 2
DISK=/dev/nvme0n1
# bcachefs partition (may be ${DISK}3 for /dev/sda)
PART="${DISK}p3"
# EFI partition
BOOT="${DISK}p1"

# Unlock if encrypted and not already unlocked. If you unlocked in a different
# session (console vs SSH), first run: keyctl link @u @s   (else mount = ENOKEY)
# bcachefs unlock "$PART"

# Root subvolume
mount -t bcachefs -o X-mount.subdir=@root "$PART" /mnt

# Boot
mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# Nix store
mkdir -p /mnt/nix
mount -t bcachefs -o X-mount.subdir=@nix "$PART" /mnt/nix

# Persist
mkdir -p /mnt/persist
mount -t bcachefs -o X-mount.subdir=@persist "$PART" /mnt/persist

# Snapshots
mkdir -p /mnt/.snapshots
mount -t bcachefs -o X-mount.subdir=@snapshots "$PART" /mnt/.snapshots
```

For non-impermanence drives (e.g. a data array), mount them where they belong:

```sh
mkdir -p /mnt/data
mount -t bcachefs UUID=<ARRAY-UUID> /mnt/data
```

Verify everything is in place:

```sh
findmnt -R /mnt
```

## Step 4: Generate Hardware Config

```sh
nixos-generate-config --no-filesystems --root /mnt
```

This creates `/mnt/etc/nixos/hardware-configuration.nix` with the correct
`boot.initrd.availableKernelModules`, `boot.kernelModules`, CPU microcode, etc.

**Important:** Even with `--no-filesystems`, the generated file may still
contain `fileSystems.*` and `swapDevices` entries. If the host uses the
impermanence module, **remove all `fileSystems` and `swapDevices` entries for
the boot drive** (`/`, `/boot`, `/nix`, `/persist`, `/snapshots`, swap) -- the
impermanence module declares these mounts itself and they will conflict.

Keep only:

- Hardware detection (`boot.initrd.availableKernelModules`, `boot.kernelModules`, etc.)
- CPU microcode (`hardware.cpu.*.updateMicrocode`)
- `nixpkgs.hostPlatform`
- `networking.useDHCP`
- `fileSystems` for **non-boot drives** that the impermanence module does not
  manage (e.g. a separate data array like h002's `/data` mount)

Copy this file back to your workstation and place it in your host config:

```sh
# From your workstation:
scp root@<IP>:/mnt/etc/nixos/hardware-configuration.nix \
  ~/.config/nixos-config/hosts/<name>/hardware-configuration.nix
```

Review the file, prune the filesystem entries as described above, then commit
and push to git so the target can fetch it.

## Step 5: Record Disk UUIDs

Get the UUIDs for the impermanence module config:

```sh
# On the target:
lsblk -o NAME,UUID,FSTYPE,SIZE
```

Update your host's `flake.nix` with the actual UUIDs:

```nix
ringofstorms.impermanence = {
  enable = true;
  disk = {
    boot = "/dev/disk/by-uuid/<BOOT-UUID>";
    primary = "/dev/disk/by-uuid/<PRIMARY-UUID>";
    swap = "/dev/disk/by-uuid/<SWAP-UUID>";  # or null
  };
  encrypted = true;
};
```

Commit and push.

## Step 6: Install

```sh
# On the target, install from the git repo:
HOST=HOSTNAME
nix flake metadata "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/$HOST" --refresh
nixos-install --no-root-password \
  --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/$HOST#$HOST" \
  --option tarball-ttl 0
```

Or build on your workstation and copy the closure straight onto the target's
disk (much faster on a beefy workstation, and required for hosts with slow
CPUs / small RAM).

**Copy into the target disk's store (`/mnt`), not the live ISO's store.** The
ISO's `/nix/store` is a small RAM-backed tmpfs: a plain
`nix-copy-closure --to root@$IP` lands there and dies with
`No space left on device` after a long, slow upload.

On the target, confirm the disk is still mounted (Step 3) before copying:

```sh
findmnt -R /mnt
```

On your workstation, from the repo root:

```sh
HOST=oren
HOST_IP=10.12.14.

# Build the system closure locally (nothing is built on the target).
CLOSURE=$(nix build "./hosts/$HOST#nixosConfigurations.$HOST.config.system.build.toplevel" \
  --no-link --print-out-paths) && echo "$CLOSURE"

# Copy it into the store under /mnt on the target. --substitute-on-destination
# lets the target fetch cache.nixos.org paths itself, so only locally-built
# paths cross the SSH link. --no-check-sigs is required: unlike
# nix-copy-closure, `nix copy` checks signatures even as root, and the fresh
# ISO does not trust the workstation's unsigned locally-built paths ("lacks a
# signature by a trusted key").
NIX_SSHOPTS="-i /var/lib/secrets_manager_hydrated/nix2nix_2026-03-15" \
  nix copy --substitute-on-destination --no-check-sigs \
  --to "ssh-ng://root@$HOST_IP?remote-store=/mnt" "$CLOSURE"

# Print the install command to run on the target.
echo "nixos-install --no-root-password --system $CLOSURE"
```

On the target, run the printed command:

```sh
nixos-install --no-root-password --system /nix/store/<...>-nixos-system-<host>-<version>
```

Use the exact store path that was copied. `$CLOSURE` only exists in the
workstation shell. `nixos-install` finds the path already present in the
`/mnt` store, so it doesn't download it again.

## Step 7 (sec-agent): first boot

For hosts that import `hosts/sec-agent.nix`. The agent authenticates to
`https://secrets.joshuabell.xyz` with a Zitadel machine key and reaches it
publicly via o002, so this works before the host is on the tailnet.

1. **Zitadel** (`https://sso.joshuabell.xyz`): create a machine user named
   after the host, or reuse the existing one when re-imaging. In the secrets
   project (`344379162166820867`), grant `device_high_trust` or
   `device_low_trust` to match the host's `sec-agent.nix` role. Under
   **Keys → + New → JSON**, download a key, and delete any old keys.
2. **Seed the key before rebooting**, from the installer with `/mnt/persist`
   mounted. Impermanence bind-mounts it to `/machine-key.json`:
   ```sh
   scp key.json root@$IP:/mnt/persist/machine-key.json
   ssh root@$IP 'chmod 400 /mnt/persist/machine-key.json'
   ```
3. **Reboot** and enter the disk passphrase. Then check, as root:
   ```sh
   journalctl -u sec-agent -b          # expect "logged in with roles [...]"
   ls /var/lib/secrets_manager_hydrated/
   ```
   An early `lookup sso.joshuabell.xyz ... server misbehaving` error is
   harmless: DNS wasn't up yet, and the agent retries.
4. **Tailscale.** If `tailscale status` says `Logged out`, autoconnect ran
   before the headscale key existed. The key is there now, so run:
   ```sh
   systemctl restart tailscaled-autoconnect && tailscale status
   ```
   Verify with `ssh o002 'sudo headscale nodes list'`: high-trust hosts show
   user `josh` with no tags, and low-trust hosts show `tag:lowtrust`. If you're
   reusing a hostname, delete any stale node there first.
5. **Deploy from lio** from now on, as `--target-host root@<host>`.

## Step 7 (legacy secrets-bao): Reboot & First Boot Setup

```sh
reboot
```

Remove the USB stick. The machine boots into the new NixOS system.

### How first-boot bootstrap works (read this once)

If the host uses `secrets-bao`, there is a deliberate **chicken-and-egg** you
need to satisfy in order:

1. The host has **no secrets** until it can authenticate to OpenBao.
2. To authenticate, `zitadel-mint-jwt` needs the host's **`/machine-key.json`**
   (a Zitadel machine key). **If that file is missing, `zitadel-mint-jwt` fails
   (exit 1) and the whole pipeline stalls** — the timer just keeps retrying
   every 10 minutes. So the machine key **must be seeded first** (7c below).
3. `vault-agent` logs into OpenBao at **`https://sec.joshuabell.xyz`** — the
   **PUBLIC edge on o002**. This is intentional and required: a brand-new
   machine is **not on the tailnet yet**, so it reaches OpenBao over the public
   internet (`sec.joshuabell.xyz` → o002 nginx → h001 OpenBao).
4. That public edge is **hardened** (default-deny path allowlist + an njs JWT
   gate — see `hosts/oracle/o002/nginx.nix`). The gate is designed to **allow
   exactly this bootstrap**: the minted Zitadel machine JWT is what passes it.
   You do **not** need to disable or special-case the gate for onboarding.
5. Only after `vault-agent` renders `headscale_auth_*` can the host join the
   tailnet (`services.tailscale.authKeyFile` points at that rendered secret).
   After joining, headscale split-DNS resolves `sec.joshuabell.xyz` to h001's
   overlay IP, so steady-state OpenBao traffic stays on the tailnet.

**So the required order is:** set password (7a) → create the Zitadel machine
identity (7b) → **seed `/machine-key.json` (7c)** → kick the pipeline (7d).
Steps 7c and 7d can also be done *before* the reboot (from the installer, over
SSH) if you prefer — the key just has to be in place before the pipeline runs.

### 7a. User password

There is **no default install password** anymore (pentest C2). `mkHost` has no
weak fallback: a host either ships a real `authValue` hash or `authValue = "!"`
(password login disabled — SSH keys only). Access a fresh box via the SSH key
(`nix2nix_2026-03-15`).

Hosts are `mutableUsers = false` by default, so `passwd` will **not** persist a
change — the password is declarative. To set/rotate a console password, put a
`mkpasswd -m yescrypt` hash in the host's `flake.nix` `authValue` and redeploy:

```sh
mkpasswd -m yescrypt        # generate a hash, paste into authValue
```

(If a host genuinely needs runtime `passwd`, set `mutableUsers = true` on it
explicitly — but prefer the declarative hash.)

### 7b. Create the machine identity in Zitadel

If the host uses `secrets-bao`, it needs a Zitadel machine token so OpenBao
can authenticate and fetch secrets. This is a one-time setup per host.

In `https://sso.joshuabell.xyz` (admin):

1. **Users → Machine Users → + New**
   - Name: the host name (e.g. `oren`, `gp3`)
   - **Access Token Type: JWT**
   - Save
2. **Projects → <the OpenBao-trusted project> → Authorizations**
   - Grant the new machine user the role(s) matching its trust tier
     (e.g. `machines-hightrust` for oren/juni, `machines-lowtrust`
     for gp3/joe).
3. Back on the machine user page: **Keys → + New**, type **JSON**,
   download the file. This is `machine-key.json`.

### 7c. Copy the key to the host

`/machine-key.json` is in the impermanence essentials persist set
(see `flakes/impermanence/shared_persistence/essentials.nix`), so the
real file lives at `/persist/machine-key.json` and is bind-mounted to
`/machine-key.json` at boot.

```sh
HOST_IP=10.12.14.124
scp -i /var/lib/openbao-secrets/nix2nix_2026-03-15 \
  ~/Downloads/<KEY-ID>.json josh@$HOST_IP:/tmp/machine-key.json

ssh josh@$HOST_IP '
  sudo install -m 0400 -o root -g root /tmp/machine-key.json /persist/machine-key.json &&
  sudo ln -sf /persist/machine-key.json /machine-key.json &&
  rm /tmp/machine-key.json
'
```

### 7d. Kick the secret-fetch pipeline

The `zitadel-mint-jwt` timer first fires 30s after boot, then every 10 minutes
(`OnBootSec=30s`, `OnUnitInactiveSec=10min`), so you don't have to wait — force
the whole chain immediately:

```sh
sudo systemctl start zitadel-mint-jwt.service &&
sudo systemctl start vault-agent.service &&
sudo systemctl start openbao-secrets-ready.service &&
sudo ls -la /var/lib/openbao-secrets/
```

Expected: a JWT lands at `/run/openbao/zitadel.jwt`, vault-agent
authenticates **against the public edge `https://sec.joshuabell.xyz`** (the host
isn't on the tailnet yet), and the host's declared secrets render under
`/var/lib/openbao-secrets/` (e.g. `headscale_auth_2026-03-15`,
`atuin-key-josh_2026-03-15`).

If something is empty, follow the logs:

```sh
journalctl -u zitadel-mint-jwt -u vault-agent -u openbao-secrets-ready -f
```

Common bootstrap failures and what they mean:

- **`zitadel-mint-jwt` exits 1 / "Missing Zitadel key JSON at /machine-key.json"**
  — you skipped or botched 7c. Seed the key, then re-run 7d.
- **`vault-agent` gets `401`/`403` from `sec.joshuabell.xyz`** — the request
  reached the hardened o002 edge but was rejected. `401` usually means the
  minted JWT is invalid/expired (bad `machine-key.json`, wrong Zitadel machine
  user, or the machine user lacks the trust-tier role from 7b step 2). `403`
  means the njs gate/allowlist blocked the path — the bootstrap login path
  (`/v1/auth/zitadel-jwt/login`) is allowed, so a 403 points at a config drift
  on o002 (`hosts/oracle/o002/nginx.nix`), not something to fix on the new host.
- **`vault-agent` connection refused / timeout** — public DNS or o002 down;
  confirm `sec.joshuabell.xyz` resolves publicly and o002 nginx is up.

### 7e. Tailscale / Headscale auto-join

Nothing to do manually. The `secrets-bao` machine-trust bundles
auto-include the headscale preauth key at:

- `/var/lib/openbao-secrets/headscale_auth_2026-03-15` (high-trust)
- `/var/lib/openbao-secrets/headscale_auth_lowtrust_2026-03-15` (low-trust)

and wire it into `services.tailscale.authKeyFile`. Once secrets render
in step 7d, kick the autoconnect:

```sh
sudo systemctl restart tailscaled-autoconnect.service
tailscale status
```

If you're reusing the host name, **remove the stale node from
headscale first** so the new register doesn't collide:

```sh
ssh o002 'sudo headscale nodes list' | grep "$HOST"
ssh o002 'sudo headscale nodes delete --identifier <id>'
```

### 7f. Trigger anything else that depended on secrets

Services declared with `hardDepend` / `softDepend` in
`_constants.nix:secrets` retry automatically once
`openbao-secrets-ready` succeeds. To kick them now:

```sh
# Atuin login (if ringofstorms.atuin.autologin.enable = true)
sudo systemctl restart atuin-autologin.service
atuin sync -f
```

### USB Key for Auto-Unlock (Optional)

If `usbKey = true` in the impermanence config, a USB stick with a bcachefs
filesystem containing a `/key` file can auto-unlock the disk at boot. The USB
drive can optionally be encrypted with `usbKeyPassword`.

See [usb_key.md](usb_key.md) for full instructions on formatting and setup.
