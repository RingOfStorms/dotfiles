# Hosts

Each subdirectory is a standalone NixOS flake for one machine.
`fleet.nix` at this level is the shared host registry and `mkHost` builder used by every host's `flake.nix`.

## `_constants.nix`

Every host has a `_constants.nix` file — the **single source of truth** for that host's service configuration.

### What goes here

- **All service ports** — including web UI ports, API ports, streaming/protocol ports, etc.
- **Data directories** (`dataDir`) for stateful services.
- **Domains** for services exposed via nginx reverse proxy.
- **UIDs/GIDs** for services that need fixed ownership.
- **Container IPs** for NixOS container-based services.

### Why

- One place to see every service and port running on a host at a glance.
- Service modules reference `constants.services.<name>.<attr>` instead of hardcoding values.
- Avoids port conflicts — all ports are visible in one file.
- The local homepage dashboard (where enabled) reads from these constants to auto-link services.

### Structure

```nix
{
  host = {
    name = "hostname";       # Must match the flake's nixosConfigurations key
    overlayIp = "100.64.x.x"; # Tailscale overlay IP
    primaryUser = "josh";    # Primary user account
    stateVersion = "26.05";  # NixOS state version
  };

  services = {
    myService = {
      port = 8080;             # Primary port (web UI or API)
      dataDir = "/var/lib/x";  # Persistent data (optional)
      domain = "x.example.com"; # Public domain (optional)
      # Additional ports, UIDs, container IPs as needed
    };
  };
}
```

### Passing constants to modules

Constants are passed via `specialArgs` by `fleet.mkHost`, so every NixOS module can access them:

```nix
{ constants, ... }:
let
  c = constants.services.myService;
in
{
  services.myService.port = c.port;
  # ...
}
```

### Note on `h001`

h001's `_constants.nix` takes `{ fleet }:` as an argument (for secret template references).
All other hosts use a plain attribute set.
