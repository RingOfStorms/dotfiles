# TODO a good readme

```nix
swapDevices = [
  {
    device = "/.swapfile";
    size = 32 * 1024; # 32GB
  }
];
```

- Copy keyfile for auto-unlock (optional)
  - `cp /tmp/keyfile_DEVICE_1 /mnt/boot/keyfile_DEVICE_1`
  - `chmod 400 /mnt/boot/keyfile_DEVICE_1`
- If Encrypted keyfile exists
  - Add to hardware config

```nix
boot.initrd.secrets = {
  "/keyfile_DEVICE_1" = "/boot/keyfile_DEVICE_1";
};

boot.initrd.luks.devices
```

2. Install and setup nixos

- nixos config and hardware config
  - `export HOSTNAME=desired_hostname_for_this_machine`
  - `export USERNAME=desired_username_for_admin_on_this_machine` (josh)
  - `nixos-generate-config --root /mnt`
  - `cd /mnt/etc/nixos`
  - `curl -O --proto '=https' --tlsv1.2 -sSf https://git.joshuabell.xyz/ringofstorms/dotfiles/raw/branch/master/onboard.sh`
  - `chmod +x onboard.sh && ./onboard.sh`
  - verify hardware config, run `nixos-install`
  - `reboot`
- log into USERNAME with `password1`, use `passwd` to change the password

> Easiest to ssh into the machine for these steps so you can copy paste...

- `cat /etc/ssh/ssh_host_ed25519_key.pub ~/.ssh/id_ed25519.pub`
  - On an already onboarded computer copy these and add them to secrets/secrets.nix file
    - `nix run github:yaxitech/ragenix -- --rules ~/.config/nixos-config/flakes/secrets/secrets.nix -r`
    - `ragenix -i ~/.ssh/ragenix_authority --rules ~/.config/nixos-config/flakes/secrets/secrets.nix -r`
  - Maybe copy hardware/configs over and setup, otherwise do it on the client machine
- git clone nixos-config `git clone https://git.joshuabell.xyz/ringofstorms/dotfiles ~/.config/nixos-config`
- Setup config as needed
  - add hosts dir and files needed
- `sudo nixos-rebuild switch --flake ~/.config/nixos-config/hosts/$HOSTNAME`
- Update remote, ssh should work now: `cd ~/.config/nixos-config && git remote remove origin && git remote add origin "ssh://git.joshuabell.xyz:3032/ringofstorms/dotfiles" && git pull origin master`

## Local tooling

- bitwarden setup/sign into self hosted vault

- atuin setup
  - if atuin is on enable that mod in configuration.nix, make sure to `atuin login` get key from existing device
  - TODO move key into secrets and mount it to atuin local share
- ssh key access, ssh iden in config in nix config

### Notes

Dual booting windows?

- If there is a new boot partition being used than the old windows one, copy over the /boot/EFI/Microsoft folder into the new boot partition, same place
- If the above auto probing for windows does not work, you can also manually add in a windows.conf in the loader entries: /boot/loader/entries/windows.conf:

```
title Windows 11
efi   /EFI/Microsoft/Boot/bootmgfw.efi
```

# Settings references

- Flake docs: <https://nixos.wiki/wiki/Flakes>
- nixos: <https://search.nixos.org/options>
- home manager: <https://nix-community.github.io/home-manager/options.xhtml>
  TODO make an offline version of this, does someone else have this already?

# TODO

# Nix Infrastructure & Automation Improvements

- [ ] **Add `isoImage` outputs for every host for instant USB/boot media creation.**  
    Use:  

    ```
    packages.x86_64-linux.install-iso = nixosConfigurations.<host>.config.system.build.isoImage;
    ```

    Then:  

    ```
    nix build .#packages.x86_64-linux.install-iso
    ```

- [ ] **Document or automate new host bootstrap:**  
  - Script or steps: boot custom ISO, git clone config, secrets onboarding (agenix), nixos-install with flake config.
  - Provide an example shell script or README note for a single-command initial setup.
- [ ] **(Optional) Add an ephemeral “vm-experiment” target for NixOS VM/dev testing.**  
  - Use new host config with minimal stateful services, then  
      `nixos-rebuild build-vm --flake .#vm-experiment`
- [ ] **Remote build reliability:**  
  - Parametrize/automate remote builder enable/disable.
  - Add quickstart SSH builder key setup instructions per-host in README.
- [ ] **Add [disko](https://github.com/nix-community/disko) to declaratively manage disk/partition creation for new installs and reinstalls.**

- work on secrets pre ragenix, stormd pre install for all the above bootstrapping steps would be ideal
- reduce home manager, make per user modules support instead
- Ensure my neovim undohistory/auto saves don't save `.age` files as they can be sensitive.

# Server hosts

simply run `deploy` in the host root and it will push changes to the server (or `deploy_[oracle|linode] <name>` from root)
