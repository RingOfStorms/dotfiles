# NixOS Install with Disko + bcachefs Impermanence

Minimal steps to get a new machine from zero to a working NixOS host with
encrypted bcachefs, impermanence, and secrets-bao.

## Prerequisites

- Network access (Ethernet recommended, or `nmtui` for Wi-Fi)
- Your host config already committed in the dotfiles repo under `hosts/<name>/`
- A USB stick flashed with a **custom NixOS ISO** that includes bcachefs kernel
  support (neither the stable nor unstable stock ISOs include it)

### Building the ISO

From your workstation, build the installer ISO from this directory's flake:

```sh
# Stable channel (nixos-25.11):
nix build "./utilities/nixos-install-disko#iso-stable"

# Unstable channel:
nix build "./utilities/nixos-install-disko#iso-unstable"
```

The ISO will be at `result/iso/nixos-*.iso`.

### Flashing to USB

```sh
DEVICE=/dev/sdX  # double-check with lsblk!
sudo dd if=result/iso/nixos-*.iso of="$DEVICE" bs=4M status=progress oflag=sync
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
ssh root@$IP -i /run/agenix/nix2nix
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
SWAP=16G           # swap partition size
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
parted -s "$DISK" mkpart ESP fat32 1MiB 3GiB
parted -s "$DISK" set 1 esp on
mkfs.fat -F32 "${DISK}p1"

# Swap (adjust size as needed)
parted -s "$DISK" mkpart swap linux-swap 3GiB 19GiB
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

## Step 3: Mount Everything Under /mnt

Whether you used disko or manual partitioning, verify the mounts are correct
before proceeding. If disko already mounted everything, check with:

```sh
mount | grep /mnt
```

If the subvolumes are not mounted (or you used manual partitioning), mount them
now. Set the partition variables to match your layout:

```sh
DISK=/dev/nvme0n1    # set this if not already set from Step 2
PART="${DISK}p3"     # bcachefs partition (may be ${DISK}3 for /dev/sda)
BOOT="${DISK}p1"     # EFI partition

# Unlock if encrypted and not already unlocked
# bcachefs unlock "$PART"

# Root subvolume
mount -t bcachefs -o subvol=@root "$PART" /mnt

# Boot
mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# Nix store
mkdir -p /mnt/nix
mount -t bcachefs -o subvol=@nix "$PART" /mnt/nix

# Persist
mkdir -p /mnt/persist
mount -t bcachefs -o subvol=@persist "$PART" /mnt/persist

# Snapshots
mkdir -p /mnt/.snapshots
mount -t bcachefs -o subvol=@snapshots "$PART" /mnt/.snapshots
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
  --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/$HOST#$HOST"
```

Or if building remotely and copying the closure:

```sh
# On your workstation (faster builds):
HOST=gp3
nixos-rebuild build --flake "./hosts/$HOST#$HOST"
NIX_SSHOPTS="-o StrictHostKeyChecking=no" \
  nix-copy-closure --to root@<IP> --use-substitutes --gzip result

# On the target:
CLOSURE=$(readlink -f /path/to/result)
nixos-install --no-root-password --system "$CLOSURE"
```

## Step 7: Reboot & First Boot Setup

```sh
reboot
```

Remove the USB stick. The machine boots into the new NixOS system.

### Secrets (OpenBao / Zitadel)

If the host uses `secrets-bao`, it needs a Zitadel machine token so OpenBao can
authenticate and fetch secrets. This is a one-time setup per host.

1. **Create a Machine User in Zitadel**
   - Log in to `https://sso.joshuabell.xyz` as an admin
   - Go to **Users > Machine Users > + New**
   - Name it after the host (e.g. `gp3`, `joe`)
   - Set **Access Token Type** to `JWT`
   - Save the user

2. **Add the machine user to the correct project**
   - Go to **Projects** > your project (the one OpenBao trusts)
   - Under **Authorizations**, grant the new machine user a role
     (this is what OpenBao checks when validating the JWT)

3. **Generate a Machine Key**
   - On the machine user page, go to **Keys > + New**
   - Select **JSON** as the key type
   - Download the key file -- this is the `machine-key.json`

4. **Copy the key to the host**
   ```sh
   scp machine-key.json josh@<HOST>:/persist/machine-key.json
   sudo ln -sf /persist/machine-key.json /machine-key.json
   sudo chmod 0400 /machine-key.json
   ```

5. **Verify the impermanence persist list** includes `/machine-key.json`
   (check `impermanence.nix` for the host)

6. Secrets will auto-provision on the next `zitadel-mint-jwt` timer fire (~30s).
   You can force it immediately with:
   ```sh
   sudo systemctl start zitadel-mint-jwt.service
   journalctl -u zitadel-mint-jwt.service -f
   ```

### USB Key for Auto-Unlock (Optional)

If `usbKey = true` in the impermanence config, a USB stick with a bcachefs
filesystem containing a `/key` file can auto-unlock the disk at boot. The USB
drive can optionally be encrypted with `usbKeyPassword`.

See [usb_key.md](usb_key.md) for full instructions on formatting and setup.

## Summary: Steps for a New Impermanence Host

| # | What | Where | Time |
|---|------|-------|------|
| 0 | Build custom ISO, flash to USB | Workstation | 10-20 min |
| 1 | Boot ISO, SSH in | Target | 2 min |
| 2a | Disko (single-drive: partition + format) | Target | 1 min |
| 2b | Manual (multi-drive / custom: partition, format, subvolumes) | Target | 5-10 min |
| 3 | Mount everything under `/mnt` (verify/fix) | Target | 1 min |
| 4 | `nixos-generate-config`, copy hardware-config | Target + Workstation | 2 min |
| 5 | Record UUIDs, update host config, push | Workstation | 3 min |
| 6 | `nixos-install --flake ...` | Target | 5-15 min |
| 7 | Reboot, setup machine key for secrets | Target | 2 min |
