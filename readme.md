<div align="center">
  <img src="icon.png" width="120" alt="logo" />
  <h1>nixos-config</h1>
  <p>Declarative NixOS configuration for my personal fleet — servers, desktops, laptops, handhelds, and cloud VMs.</p>
</div>

---

Every machine is its own flake under `hosts/`, built from a shared registry
(`hosts/fleet.nix`) and a library of reusable modules under `flakes/`. Common
infrastructure — secrets, impermanence, monitoring, desktops — is factored into
standalone flakes that any host can import.

## Repository layout

```
.
├── flake.nix              # Root dev flake: deploy_<host> scripts + `nix run .#audit`
├── hosts/                 # One flake per machine
│   ├── fleet.nix          #   Fleet registry + mkHost builder (single source of truth)
│   ├── README.md          #   Explains _constants.nix convention
│   └── <host>/            #   Per-host flake, _constants.nix, hardware-configuration.nix, service mods/
├── flakes/                # Reusable, independently-versioned modules (imported by hosts)
│   ├── common/            #   Shared NixOS + Home Manager modules (the base layer)
│   ├── secrets-bao/       #   OpenBao + Zitadel secret management
│   ├── impermanence/      #   Boot-time root wipe (bcachefs) + shared persistence sets
│   ├── containers/        #   Independently deployable NixOS containers (extra-container)
│   ├── beszel/            #   Beszel monitoring agent/hub
│   ├── de_plasma/         #   KDE Plasma desktop (plasma-manager)
│   ├── hyprland/          #   Hyprland desktop
│   ├── flatpaks/          #   nix-flatpak integration
│   ├── stt_ime/           #   Local speech-to-text input method for Fcitx5
│   └── ports/             #   SSH port-forwarding TUI (Go)
├── utilities/
│   ├── nixos-install-disko/  # Installer ISO + full bring-up guide (see below)
│   └── impermanence.md       # Diffing the live root against the last snapshot
├── scripts/
│   ├── audit/             #   Security auditor (lock staleness + CVE scan)
│   └── probe-copilot-models.sh
└── ideas/                 # Design docs / future-work notes
```

## The fleet

Each host is a standalone flake. `fleet.nix` holds the registry (IPs, trust
tier, SSH config) and `mkHost`, which eliminates per-host boilerplate (users,
Home Manager, secrets wiring, state version). Every host also has a
`_constants.nix` — the single source of truth for its service ports, data
directories, and domains.

| Host | Role | Hardware (mem, cpu, gfx)|
|------|------|----------|
| **h001** | Primary home server — media, matrix, immich, paperless, vaultwarden, git, LLM gateways, SSO, secrets | OptiPlex 7090 (64GB, i5-11500, Intel UHD Grpahics 750) |
| **h002** | NAS (multi-disk bcachefs array) | My first PC's 14+ year old mobo in a case with many drives (18GB, i7-3770K, AMD Radeon HD 7950/8950 OEM / R9 280)|
| **h003** | WAN / local networking box | GMKtec M5 PLUS (32GB, AMD Ryzen 7 5825U, AMD Barcelo)|
| **i001** | Intel NUC testbed | Amazon mini pc (16GB, Intel N95, UHD Graphics)|
| **lio** | Main workstation | System76 Thelio (64GB, AMD Ryzen 9 9950X, AMD Radeon RX 7900 GRE)|
| **oren** | Mobile workstation | Framework 16 (...)|
| **juni** | Mobile terminal | Framework 12 (...)|
| **joe** | Gaming PC | HP Omen 30L (32GB, i7-10700K, RTX 3080)|
| **gp3** | Media box in living room| GPD Pocket 3 (16GB, i7-1195G7, Iris Xe Graphics)|
| **oracle/o002** | Public static IP gateway | Oracle aarch64 VM, 50% free tier (12GB, Neoverse-N1*2, Virtio)|
| **testbed** | Throwaway VM for disko/impermanence experiments ||

## Deploying

The root dev shell exposes a `deploy_<host>` script for every deployable host:

```sh
nix develop            # or: direnv allow  (auto-loads via .envrc)
deploy_lio             # build + push to the host over SSH
```

Or drive `nixos-rebuild` directly against a host's flake:

```sh
nixos-rebuild switch --flake ./hosts/<host>#<host> --target-host <host>
```

Most machines pull the shared `flakes/*` from the git remote, so **commit and
push before deploying** a host that isn't building from a local path.

## Installing a new machine

Bring-up (custom ISO → disko + bcachefs → impermanence → secrets bootstrap) is
documented separately:

➡️ **[`utilities/nixos-install-disko/readme.md`](utilities/nixos-install-disko/readme.md)**

New Oracle Cloud instances follow [`hosts/oracle/readme.md`](hosts/oracle/readme.md).

## Security auditing

Scan every `flake.lock` for stale/off-branch nixpkgs inputs and match CVEs
against built host closures:

```sh
nix run .#audit                 # lock staleness (all) + CVE scan (current host)
nix run .#audit -- --all        # CVE scan every deployable host
nix run .#audit -- --host lio   # one host
nix run .#audit -- --stale-only # skip the (slow) CVE builds
```

See [`scripts/audit/audit.sh`](scripts/audit/audit.sh) for details. `0` clean,
`1` staleness warnings, `2` vulnerabilities found.

## References

- Flakes: <https://nixos.wiki/wiki/Flakes>
- NixOS options: <https://search.nixos.org/options>
- Home Manager options: <https://nix-community.github.io/home-manager/options.xhtml>
