# NixOS Install with Disko + bcachefs Impermanence

Minimal steps to get a new machine from zero to a working NixOS host with
encrypted bcachefs, impermanence, and secrets-bao.

## Prerequisites

- A USB stick flashed with the [NixOS minimal ISO](https://nixos.org/download/#nixos-iso)
  (any recent release, stable or unstable)
- Network access (Ethernet recommended, or `nmtui` for Wi-Fi)
- Your host config already committed in the dotfiles repo under `hosts/<name>/`

## Step 1: Boot the ISO & Enable SSH

Boot the target machine from the NixOS minimal USB.

```sh
# Set root password so you can SSH in from another machine
passwd

# Check the IP
ip a
```

From your workstation (lio, oren, etc.), SSH in:

```sh
ssh nixos@<IP>
```

## Step 2: Enable Flakes + bcachefs

Run this one-liner on the target to enable flakes and bcachefs for the session:

```sh
export NIX_CONFIG="experimental-features = nix-command flakes"
```

## Step 3: Partition & Mount

Pick **one** of the two approaches below. Disko is the quick path for simple
single-drive machines. For multi-drive arrays or unusual layouts, use the manual
approach.

```sh
lsblk
```

### Step 3a: Disko (single-drive)

Best for typical desktops/laptops with one NVMe or SSD. The disko config lives
in `flakes/impermanence/disko-bcachefs.nix` and creates:

- **Partition 1**: EFI System Partition (FAT32, 1GB)
- **Partition 2**: Swap (configurable, default 8G)
- **Partition 3**: bcachefs (rest of disk, optionally encrypted)
  - Subvolumes: `@root`, `@nix`, `@snapshots`, `@persist`

#### Encrypted (recommended)

```sh
# Write your disk encryption passphrase to a temp file
echo -n 'your-passphrase' > /tmp/bcachefs.key

# Run disko -- replace /dev/nvme0n1 and 16G with your values
nix run github:nix-community/disko/latest -- \
  --mode destroy,format,mount \
  /etc/nixos/disko-bcachefs.nix \
  --arg disk '"/dev/nvme0n1"' \
  --arg swapSize '"16G"' \
  --arg encrypted true

# Clean up the key file
rm /tmp/bcachefs.key
```

If fetching the file from the repo directly:

```sh
curl -o /etc/nixos/disko-bcachefs.nix \
  https://git.joshuabell.xyz/ringofstorms/dotfiles/raw/branch/master/flakes/impermanence/disko-bcachefs.nix
```

#### Unencrypted

```sh
nix run github:nix-community/disko/latest -- \
  --mode destroy,format,mount \
  /etc/nixos/disko-bcachefs.nix \
  --arg disk '"/dev/nvme0n1"' \
  --arg swapSize '"16G"'
```

After disko completes, everything is mounted under `/mnt`.

### Step 3b: Manual partitioning (multi-drive / custom layouts)

For machines with multi-disk arrays, mixed filesystems, or other layouts that
don't fit the single-drive disko template (e.g. h002's 5-disk bcachefs array
with replication).

#### 1. Partition the boot drive

```sh
DISK=/dev/nvme0n1  # or /dev/sda, etc.

# Create GPT table
parted -s "$DISK" mklabel gpt

# EFI System Partition (1GB)
parted -s "$DISK" mkpart ESP fat32 1MiB 1GiB
parted -s "$DISK" set 1 esp on
mkfs.fat -F32 "${DISK}p1"

# Swap (adjust size as needed)
parted -s "$DISK" mkpart swap linux-swap 1GiB 17GiB
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

#### 4. Mount everything under /mnt

```sh
# Root subvolume
mount -t bcachefs -o subvol=@root "${DISK}p3" /mnt

# Boot
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot

# Nix store
mkdir -p /mnt/nix
mount -t bcachefs -o subvol=@nix "${DISK}p3" /mnt/nix

# Persist
mkdir -p /mnt/persist
mount -t bcachefs -o subvol=@persist "${DISK}p3" /mnt/persist

# Snapshots
mkdir -p /mnt/snapshots
mount -t bcachefs -o subvol=@snapshots "${DISK}p3" /mnt/snapshots
```

For non-impermanence drives (e.g. a data array), mount them where they belong:

```sh
mkdir -p /mnt/data
mount -t bcachefs UUID=<ARRAY-UUID> /mnt/data
```

After all mounts are in place under `/mnt`, continue to Step 4.

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
HOST=gp3
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

If `usbKey = true` in the impermanence config, format a USB stick as bcachefs
and write the disk passphrase as the key. The unlock service scans all USB block
devices for a bcachefs partition with a `/key` file at boot.

#### Unencrypted USB key (simplest)

```sh
DEVICE=sdX1
bcachefs format /dev/$DEVICE
mount -t bcachefs --mkdir /dev/$DEVICE /tmp/usb_key
# Write the same passphrase used during disko encryption
echo -n 'your-passphrase' > /tmp/usb_key/key
umount /tmp/usb_key
```

#### Encrypted USB key (recommended)

If `usbKeyPassword` is also set in the config, the USB drive itself can be
encrypted. This prevents trivial exposure of the disk passphrase if the USB key
is lost separately from the machine. The password is a publicly-known secret
baked into the NixOS config -- it only adds a thin layer against casual reads.

```nix
ringofstorms.impermanence = {
  usbKey = true;
  usbKeyPassword = "some-known-password";
};
```

Format the USB stick with encryption:

```sh
DEVICE=sdX1
echo -n 'some-known-password' > /tmp/usb.key
bcachefs format --encrypted --passphrase_file=/tmp/usb.key /dev/$DEVICE
bcachefs unlock -f /tmp/usb.key /dev/$DEVICE
mount -t bcachefs --mkdir /dev/$DEVICE /tmp/usb_key
echo -n 'your-disk-passphrase' > /tmp/usb_key/key
umount /tmp/usb_key
rm /tmp/usb.key
```

The unlock service tries unencrypted mounts first, then attempts the configured
`usbKeyPassword` on any drives that fail to mount. If no USB key is found, it
falls back to an interactive passphrase prompt as usual.

## Summary: Steps for a New Impermanence Host

| # | What | Where | Time |
|---|------|-------|------|
| 1 | Boot NixOS ISO, set passwd, SSH in | Target | 2 min |
| 2 | `export NIX_CONFIG=...` | Target | 5 sec |
| 3a | Disko (single-drive: partition + format + mount) | Target | 1 min |
| 3b | Manual (multi-drive / custom: partition, format, mount) | Target | 5-10 min |
| 4 | `nixos-generate-config`, copy hardware-config | Target + Workstation | 2 min |
| 5 | Record UUIDs, update host config, push | Workstation | 3 min |
| 6 | `nixos-install --flake ...` | Target | 5-15 min |
| 7 | Reboot, setup machine key for secrets | Target | 2 min |
