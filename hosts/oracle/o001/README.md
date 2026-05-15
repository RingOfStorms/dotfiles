# o001

Oracle Cloud aarch64 VM. **Tiny `/boot` (200M) and tight `/` (42G)** — see deploy notes below before pushing a new kernel.

## Pre-deploy checklist (run before `nixos-rebuild switch --target-host o001`)

When `nixpkgs` updates bring a new kernel, the new kernel + initrd (~70M) must fit in `/boot` *alongside* the currently-booted kernel. With the default GRUB behaviour every prior generation also keeps its kernel in `/boot`, so the partition fills fast.

Before deploying, SSH in and check headroom:

```sh
ssh o001 'df -h /boot && ls -lah /boot/kernels/'
```

If `/boot` is above ~60% used, prune old generations first:

```sh
# List generations — keep at least the current one as a fallback
ssh o001 'nix-env --list-generations --profile /nix/var/nix/profiles/system'

# Delete everything except the current generation (replace N with the current number)
ssh o001 'nix-env --delete-generations --profile /nix/var/nix/profiles/system old'

# Free store space and rebuild grub.cfg so /boot drops the orphaned kernels
ssh o001 'nix-collect-garbage -d && /run/current-system/bin/switch-to-configuration boot'

# Verify
ssh o001 'df -h /boot && ls -lah /boot/kernels/'
```

After a successful deploy + reboot on the new kernel, repeat the cleanup so the *next* deploy starts with maximum headroom:

```sh
ssh o001 'nix-env --delete-generations --profile /nix/var/nix/profiles/system old \
  && nix-collect-garbage -d \
  && /run/current-system/bin/switch-to-configuration boot'
```

## Recovering from a failed bootloader install

If `nixos-rebuild` fails partway with `No space left on device` during `updating GRUB 2 menu...`:

1. The system *profile* has already advanced to the new (broken) generation, but `/run/current-system` and the bootloader still point at the previous one — so the box is still bootable on the old kernel until you reboot.
2. Delete the stranded `*.tmp` file in `/boot/kernels/` left by the failed copy.
3. Roll the profile back so `switch-to-configuration boot` will reinstall against the *known-good* generation (otherwise it just retries the failing install):
   ```sh
   ssh o001 'nix-env --rollback --profile /nix/var/nix/profiles/system'
   ssh o001 'nix-env --delete-generations --profile /nix/var/nix/profiles/system <failed-gen-number>'
   ```
4. Clean up old generations and orphaned kernels (see above).
5. Re-run the deploy.

## Why not just raise `configurationLimit`?

We *could* set `boot.loader.grub.configurationLimit = 3` (or similar) in `hardware-configuration.nix` to cap how many generations live in `/boot`. That's a reasonable change to make if this keeps biting — but it silently throws away rollback targets, so for now the convention is manual pruning before kernel-bumping deploys.

The kernel is also pinned to `linuxPackages_6_12` in `hardware-configuration.nix` to avoid jumping to a larger kernel series on this constrained partition.
