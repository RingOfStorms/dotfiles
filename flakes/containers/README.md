# Extra Containers

Lightweight, independently deployable NixOS containers managed via
[extra-container](https://github.com/erikarvstedt/extra-container). Each
service lives in its own sub-directory with a standalone flake that can be
built, started, updated, and destroyed without a full `nixos-rebuild` on the
host.

## Architecture

```
flakes/containers/
  flake.nix              # Parent flake: owns the extra-container input,
                         #   exports NixOS module + shared lib
  minecraft/             # One container per service
    flake.nix            # Uses parent's lib to define the container
    container.nix        # NixOS config that runs inside the container
    README.md            # Service-specific docs
  some-future-service/
    ...
```

### How it works

1. **Parent flake** (`flake.nix`) pins `extra-container` once. It exports:
   - `nixosModules.default` -- import this on any host to install the
     `extra-container` binary and enable `programs.extra-container`.
   - `lib` -- the `extra-container` library (notably `buildContainers` and
     `eachSupportedSystem`), passed through so child flakes use the same
     version as the host binary.

2. **Child flakes** (e.g. `minecraft/flake.nix`) reference the parent via
   `containers.url = "path:..";` and call `containers.lib.buildContainers`
   to define their container. This guarantees the host binary and the
   container build lib are always from the same `extra-container` version.

3. **Containers are systemd-nspawn** under the hood. They use the standard
   NixOS container infrastructure (`nixos-container` CLI, systemd units).
   `extra-container` just decouples them from the host's NixOS closure so
   they can be managed independently.

4. **State persists** at `/var/lib/nixos-containers/<name>/` on the host.
   No bind mounts needed -- the container's filesystem is a regular
   directory tree on disk.

## Host Setup

Any host that wants to run extra-containers needs one thing: import the
parent NixOS module.

```nix
# In hosts/<hostname>/flake.nix inputs:
containers.url = "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=flakes/containers";

# In nixosModules list:
inputs.containers.nixosModules.default
```

Then `nixos-rebuild switch` once to install the `extra-container` binary.
After that, containers are managed imperatively -- no further host rebuilds
needed for container changes.

## Common Operations

All commands are run from a container's directory (e.g.
`flakes/containers/minecraft/`).

### Create / Start

```bash
nix run . -- create --start
```

Builds the container config and starts it. If the container already exists
and is running, this updates it in-place via `switch-to-configuration`
inside the container (like a mini `nixos-rebuild switch`).

### Update After Config Changes

```bash
# Same command -- it detects changes and applies them
nix run . -- create --start
```

For changes that require a full container restart rather than a switch:

```bash
nix run . -- create --restart-changed
```

### Stop

```bash
sudo nixos-container stop <name>
```

### Start (existing container)

```bash
sudo nixos-container start <name>
```

### Destroy

```bash
# Stops and removes the container (systemd units + /etc links)
nix run . -- destroy
```

This does **not** delete persistent data in
`/var/lib/nixos-containers/<name>/`. To fully clean up:

```bash
nix run . -- destroy
sudo rm -rf /var/lib/nixos-containers/<name>
```

### Shell (ephemeral)

```bash
# Start an interactive shell in a temporary container
nix run . -- shell

# Run a single command and exit
nix run . -- --run c hostname
```

### Root Login

```bash
sudo nixos-container root-login <name>
```

### List Extra Containers

```bash
extra-container list
```

### Status

```bash
sudo nixos-container status <name>
```

## Migrating a Service Between Hosts

Moving a container from one host to another requires no config changes to
the container flake itself. The same flake runs identically on any host.

### Steps

1. **Backup state on the source host:**

   ```bash
   sudo tar -czf <name>-$(date +%F).tar.gz \
     /var/lib/nixos-containers/<name>/
   ```

2. **Copy to target host:**

   ```bash
   scp <name>-*.tar.gz target-host:/tmp/
   ```

3. **On target host -- ensure prerequisites:**
   - Host has `extra-container` installed (import `containers.nixosModules.default`)
   - Any required firewall ports are open
   - `nixos-rebuild switch` has been run at least once with the module

4. **Restore state on target host:**

   ```bash
   sudo tar -xzf /tmp/<name>-*.tar.gz -C /
   ```

5. **Start the container on the target:**

   ```bash
   # From the container's flake directory (cloned repo)
   nix run . -- create --start
   ```

6. **Destroy on the source host:**

   ```bash
   nix run . -- destroy
   ```

The container picks up exactly where it left off with all its data intact.

## Backup Strategy

Each container's state is self-contained under
`/var/lib/nixos-containers/<name>/`. A simple tar/rsync of that directory
captures everything.

For services with databases, run a dump **inside the container** before
backing up the directory:

```bash
sudo nixos-container run <name> -- pg_dumpall -U postgres \
  | zstd > /var/lib/nixos-containers/<name>/backup-$(date +%F).sql.zst
```

For automated backups, a host-level restic job can include
`/var/lib/nixos-containers/` in its paths.

## Adding a New Container

1. Create a new directory under `flakes/containers/<service-name>/`
2. Add a `flake.nix` that references the parent:

   ```nix
   {
     inputs = {
       containers.url = "path:..";
       nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
       # ... any service-specific inputs
     };

     outputs = { containers, nixpkgs, ... }:
       containers.lib.eachSupportedSystem (system: {
         packages.default = containers.lib.buildContainers {
           inherit system nixpkgs;
           config.containers.<service-name> = {
             config = import ./container.nix;
           };
         };
       });
   }
   ```

3. Add a `container.nix` with the NixOS configuration for inside the container
4. `nix flake lock` to generate the lock file
5. Open any needed firewall ports on the host
6. `nix run . -- create --start`

## Updating extra-container

Run `nix flake update` in `flakes/containers/` to update the shared
`extra-container` pin. Then:

1. Rebuild each host that imports the module (`nixos-rebuild switch`) to
   update the binary
2. Re-run `nix run . -- create --start` in each container directory to
   rebuild with the new lib

Since both sides use the same `flake.lock`, they stay in sync.
