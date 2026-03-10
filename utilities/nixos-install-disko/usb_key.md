# USB Key for bcachefs Auto-Unlock

A USB stick formatted as bcachefs containing a `/key` file can automatically
unlock an encrypted bcachefs root partition at boot. The USB drive itself can
optionally be encrypted to prevent trivial exposure if physically lost.

## Prerequisites

- `bcachefs-tools` installed (available in the NixOS ISO and on any impermanence host)
- A USB stick (any size)
- The disk encryption passphrase used when partitioning the host

## Identify the USB Device

```sh
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Look for the USB device (typically `/dev/sdX`). Formatting the whole device is
simpler than targeting a partition.

**Double-check you have the right device.** The next step destroys all data on it.

```sh
DEVICE=/dev/sdX
```

## Option A: Unencrypted USB Key

Anyone with physical access to the USB stick can read the key.

```sh
sudo bcachefs format "$DEVICE"

mkdir -p /tmp/usb_key
mount -t bcachefs "$DEVICE" /tmp/usb_key

echo -n 'your-disk-passphrase' > /tmp/usb_key/key

umount /tmp/usb_key
```

## Option B: Encrypted USB Key

The drive is encrypted with a password matching `usbKeyPassword` in the NixOS
config. Not strong security -- the password is in the config -- but it prevents
casual reads if the stick is lost.

`bcachefs format --encrypted` prompts for the passphrase interactively.
`bcachefs unlock` also prompts interactively.

```sh
sudo bcachefs format --encrypted "$DEVICE"
sudo bcachefs unlock "$DEVICE"

sudo mkdir -p /tmp/usb_key && sudo mount -t bcachefs "$DEVICE" /tmp/usb_key
sudo $EDITOR /tmp/usb_key/key

sudo umount /tmp/usb_key
```

## Verify

```sh
# Unencrypted:
mkdir -p /tmp/verify
mount -t bcachefs -o ro "$DEVICE" /tmp/verify
cat /tmp/verify/key
umount /tmp/verify

# Encrypted:
bcachefs unlock "$DEVICE"
mkdir -p /tmp/verify
mount -t bcachefs -o ro "$DEVICE" /tmp/verify
cat /tmp/verify/key
umount /tmp/verify
```

The output should match the disk encryption passphrase exactly.

## Replacing a Key

1. Mount the USB drive (unlock first if encrypted)
2. Overwrite the key file: `echo -n 'new-passphrase' > /mountpoint/key`
3. Unmount

No reformat needed.

## Boot Behavior

The unlock service runs in the initrd before root is mounted:

1. Waits up to 4 seconds for USB devices to appear
2. Scans all `/dev/sd*` block devices (skips the primary disk)
3. Tries unencrypted mount first, then encrypted unlock if `usbKeyPassword` is set
4. Reads `/key` and uses it to unlock the primary partition
5. Falls back to interactive passphrase prompt if no key is found

The USB stick can be removed after boot completes.
