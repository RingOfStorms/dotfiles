# Hosts

Each subdirectory is a standalone NixOS flake for one machine.
`fleet.nix` at this level is the shared host registry and `mkHost` builder used by every host's `flake.nix`.

## Firewall

Servers (h001, h003, h004, h005, i001, joe, lio) generate their rules from `fleet.nix` and `containers/lib.nix`, in
each host's `firewall.nix` (lio: `configuration.nix`).

- **No host trusts `tailscale0`.** The shared tailnet module's `trustInterface` defaults to `false`, so tailnet peers
  reach only what a host opens explicitly: sshd, its nginx listeners and declared `proto` routes.
- **ssh** is allowed only from high-trust overlay IPs (`firewallHighTrustIps` and `firewallHighTrustIps6`: the
  `trust = "high"` hosts minus o002 and the host itself), on `tailscale0`, for IPv4 and IPv6. Hosts on the home LAN
  also accept ssh from the LAN subnet as a fallback when the tailnet is down; `lowTrustLanSshTable` still rejects
  low-trust devices there. On every server except lio (which excludes itself), `sshGuardAssertion` fails evaluation
  if either list is empty or misses lio's overlay IP, so a typo cannot lock lio out. o002 keeps a global `:22` as a
  deliberate break-glass exception; the laptops keep a global `:22` too.
- **80/443** sources come from runtime nft sets (`@src`, `@src6`, `@src_lan`) that `cnt deploy` and `cnt move` fill
  from the routes of the services placed on that host, with no rebuild. An empty set means closed. nginx still
  enforces each vhost's exposure ACL; the firewall only admits. h005's own 80/443 is the tailnet minus
  `tailnetExcludedOverlayIps` (o002 and low-trust nodes), because `sso-proxy` must reach phones that are not in
  `fleet.nix`.
- **`nginx.extraWebSources`** is only for hand-written vhosts that the inventory cannot see (h001's arr block, set
  in `h001/floating-containers.nix`). It adds static sources on top of the runtime sets; container routes never
  need it.

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
