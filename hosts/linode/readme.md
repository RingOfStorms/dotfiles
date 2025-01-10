# Linode setup

<https://www.linode.com/docs/guides/install-nixos-on-linode/#prepare-your-linode>
<https://nixos.org/download/>

- shutdown linode
- delete existing disks and configuration profiles
- Create Disks
  - `installer`: `ext4` `1280 MB`
  - `swap`: `swap` `512 MB`
  - `nixos`: `ext4` all remaining space
- Create two configuration profiles, one for the installer and one to boot NixOS. For each profile, disable all of the options under Filesystem/Boot Helpers and set the Configuration Profile to match the following:
  - installer profile
    - Label: installer
    - Kernel: Direct Disk
    - /dev/sda: nixos
    - /dev/sdb: swap
    - /dev/sdc: installer
    - root / boot device: Standard: `/dev/sdc`
  - nixos profile
    - Label: nixos
    - Kernel: GRUB 2
    - /dev/sda: nixos
    - /dev/sdb: swap
    - root / boot device: Standard: `/dev/sda`
- Setup installer.
  - rescue mode with installer as /dev/sda
  - Open LISH

```bash
# Update SSL certificates to allow HTTPS connections:
update-ca-certificates
# set the iso url to a variable
iso=https://channels.nixos.org/nixos-24.11/latest-nixos-minimal-x86_64-linux.iso
# verify sda disk is installer (~1GB)
lsblk
curl -L https://channels.nixos.org/nixos-24.11/latest-nixos-minimal-x86_64-linux.iso.sha256
# Download the ISO, write it to the installer disk, and verify the checksum:
curl -L $iso | tee >(dd of=/dev/sda) | sha256sum
# verify the shas are the same then shutdown system
shutdown 0
```

- Boot the installer configuration profile and install nixos
(open GLISH and `sudo -i && passwd #simple pass` ssh into machine for easier copy paste, rerun `passwd` with a more secure password here if desired)
  - mount /dev/sda /mnt
  - swapon /dev/sdb
  - nixos-generate-config --root /mnt
  - cd /mnt/etc/nixos

- # TODO rewrite device modifiers like they say in the tutorial? I had issues with linode's device labeling so I am leaving it to uuids, this could bite me in the future idk

  - copy `linode.nix` into remote server and import it into `configuration.nix`
    - update ssh key for root user if needed
  - `nixos-install`
- shutdown in linode, delete installer disk
- delete the installer configuration profile in linode, boot into nixos configuration profile


tada, should be able to ssh with root and ssh key defined in earlier in linode.nix
