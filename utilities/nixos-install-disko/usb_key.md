# USB Key for bcachefs Auto-Unlock

A USB stick formatted as **encrypted** bcachefs, holding a `/key` file, unlocks an
encrypted bcachefs root at boot. The stick is always encrypted. Its password is set
in the host config as `usbKeyPassword` and baked into the initrd, so the box
unlocks unattended with the stick plugged in.

What this protects: **a stick lost on its own.** Whoever finds it can't read the disk
passphrase without the stick password. What it doesn't protect: the password is in
the repo, the Nix store and the unencrypted `/boot` of the host, so someone with
the repo or the machine can open the stick. If a stick is lost, change the disk
passphrase anyway.

## Prerequisites

- `bcachefs-tools` (in the NixOS install ISO and on every impermanence host)
- A USB stick (any size), not the installer stick
- The disk encryption passphrase used when formatting the host
- A stick password: generate one (`xkcdpass -n 3 -d -`) and set it as
  `ringofstorms.impermanence.usbKeyPassword` in `hosts/<name>/flake.nix`. Use a new
  password per host

## Version match

Format the stick at the **host's** bcachefs version, not the installer's, and mount it
with `version_upgrade=none`. Otherwise a newer installer kernel upgrades it on first
mount and the host's initrd can't read it. Check the host's version with
`nix eval --raw ./hosts/<name>#nixosConfigurations.<name>.config.boot.kernelPackages.bcachefs.version`
(e.g. `6.18.44-1.38.8` → `--version=1.38`).

## Make the stick

```sh
bash   # the install ISO's root shell is zsh; `read -p` there can write an empty file
lsblk -o NAME,SIZE,TRAN,MODEL,FSTYPE   # the stick shows TRAN=usb
K=/dev/sdX                             # double-check: this destroys it
V=1.38                                 # host's bcachefs version

# Stick password must equal usbKeyPassword; stop on empty input
read -rs -p 'stick password: ' X && [ -n "$X" ] || { echo 'empty, stop'; exit 1; }; echo
printf %s "$X" > /tmp/usb.pw
read -rs -p 'disk passphrase: ' X && [ -n "$X" ] || { echo 'empty, stop'; exit 1; }; echo
printf %s "$X" > /tmp/disk.key; unset X

bcachefs format --version=$V --encrypted --passphrase_file=/tmp/usb.pw "$K"
bcachefs unlock -f /tmp/usb.pw "$K" && keyctl link @u @s
mkdir -p /tmp/k && mount -t bcachefs -o version_upgrade=none "$K" /tmp/k
install -m 0400 /tmp/disk.key /tmp/k/key
umount /tmp/k
shred -u /tmp/usb.pw /tmp/disk.key
bcachefs show-super "$K" | grep -E '^Version|Oldest'   # must match $V
```

## Verify

```sh
bcachefs unlock "$K"          # stick password
mkdir -p /tmp/verify && mount -t bcachefs -o ro,nochanges,version_upgrade=none "$K" /tmp/verify
cmp /tmp/verify/key <(printf %s 'disk passphrase')   # silent = match
umount /tmp/verify
```

The real test is a reboot of the host: it should unlock with no prompt, and with the
stick pulled it should ask for the disk passphrase.

## Replacing a Key

1. Unlock with the stick password, then mount with `-o version_upgrade=none`
2. Overwrite the key file: `echo -n 'new-passphrase' > /mountpoint/key`
3. Unmount

No reformat needed.

## Boot Behavior

The unlock service runs in the initrd before root is mounted:

1. Waits up to 6 seconds for USB devices to appear
2. Scans `/dev/sd*` devices **attached over USB only** (SATA/SAS disks such as a data
   pool are skipped, as is the primary disk). Probe mounts use
   `ro,nochanges,version_upgrade=none`, so they never write to a device
3. Unlocks encrypted sticks with `usbKeyPassword` (an unencrypted stick still works, but
   don't make new ones)
4. Reads `/key` and uses it to unlock the primary partition
5. Falls back to interactive passphrase prompt if no key is found

The USB stick can be removed after boot completes.
