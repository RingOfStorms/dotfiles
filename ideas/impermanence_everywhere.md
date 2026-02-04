# Impermanence Rollout Strategy

## Overview

This document covers rolling out impermanence (ephemeral root filesystem) to all hosts, using Juni as the template.

## What is Impermanence?

**Philosophy:** Root filesystem (`/`) is wiped on every boot (tmpfs or reset subvolume), forcing you to explicitly declare what state to persist.

**Benefits:**
- Clean system by default - no accumulated cruft
- Forces documentation of important state
- Easy rollback (just reboot)
- Security (ephemeral root limits persistence of compromises)
- Reproducible server state

## Current State

| Host | Impermanence | Notes |
|------|--------------|-------|
| Juni | ✅ Implemented | bcachefs with @root/@persist subvolumes |
| H001 | ❌ Traditional | Most complex - many services |
| H002 | ❌ Traditional | NAS - may not need impermanence |
| H003 | ❌ Traditional | Router - good candidate |
| O001 | ❌ Traditional | Gateway - good candidate |
| L001 | ❌ Traditional | Headscale - good candidate |

## Juni's Implementation (Reference)

### Filesystem Layout

```
bcachefs (5 devices, 2x replication)
├── @root      # Ephemeral - reset each boot
├── @nix       # Persistent - Nix store
├── @persist   # Persistent - bind mounts for state
└── @snapshots # Automatic snapshots
```

### Boot Process

1. Create snapshot of @root before reset
2. Reset @root subvolume (or recreate)
3. Boot into clean system
4. Bind mount persisted paths from @persist

### Persisted Paths (Juni)

```nix
environment.persistence."/persist" = {
  hideMounts = true;
  
  directories = [
    "/var/log"
    "/var/lib/nixos"
    "/var/lib/systemd"
    "/var/lib/tailscale"
    "/var/lib/flatpak"
    "/etc/NetworkManager/system-connections"
  ];
  
  files = [
    "/etc/machine-id"
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_ed25519_key.pub"
    "/etc/ssh/ssh_host_rsa_key"
    "/etc/ssh/ssh_host_rsa_key.pub"
  ];
  
  users.josh = {
    directories = [
      ".ssh"
      ".gnupg"
      "projects"
      ".config"
      ".local/share"
    ];
  };
};
```

### Custom Tooling

Juni has `bcache-impermanence` with commands:
- `ls` - List snapshots
- `gc` - Garbage collect old snapshots
- `diff` - Show changes since last boot (auto-excludes persisted paths)

Retention policy: 5 recent + 1/week for 4 weeks + 1/month

---

## Common Pain Point: Finding What Needs Persistence

> "I often have issues adding new persistent layers and knowing what I need to add"

### Discovery Workflow

#### Method 1: Use the Diff Tool

Before rebooting after installing new software:

```bash
# On Juni
bcache-impermanence diff
```

This shows files created/modified outside persisted paths.

#### Method 2: Boot and Observe Failures

```bash
# After reboot, check for failures
journalctl -b | grep -i "no such file"
journalctl -b | grep -i "failed to"
journalctl -b | grep -i "permission denied"
```

#### Method 3: Monitor File Changes

```bash
# Before making changes
find /var /etc -type f -printf '%T@ %p\n' 2>/dev/null | sort -n > /tmp/before.txt

# After running services
find /var /etc -type f -printf '%T@ %p\n' 2>/dev/null | sort -n > /tmp/after.txt

# Compare
diff /tmp/before.txt /tmp/after.txt
```

#### Method 4: Service-Specific Patterns

Most services follow predictable patterns:

| Pattern | Example | Usually Needs Persistence |
|---------|---------|---------------------------|
| `/var/lib/${service}` | `/var/lib/postgresql` | Yes |
| `/var/cache/${service}` | `/var/cache/nginx` | Usually no |
| `/var/log/${service}` | `/var/log/nginx` | Optional |
| `/etc/${service}` | `/etc/nginx` | Only if runtime-generated |

---

## Server Impermanence Template

### Minimal Server Persistence

```nix
environment.persistence."/persist" = {
  hideMounts = true;
  
  directories = [
    # Core system
    "/var/lib/nixos"           # NixOS state DB
    "/var/lib/systemd/coredump"
    "/var/log"
    
    # Network
    "/var/lib/tailscale"
    "/etc/NetworkManager/system-connections"
    
    # ACME certificates
    "/var/lib/acme"
  ];
  
  files = [
    "/etc/machine-id"
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_ed25519_key.pub"
    "/etc/ssh/ssh_host_rsa_key"
    "/etc/ssh/ssh_host_rsa_key.pub"
  ];
};
```

### Per-Host Additions

#### H001 (Services)

```nix
environment.persistence."/persist".directories = [
  # Add to minimal template:
  "/var/lib/forgejo"
  "/var/lib/zitadel"
  "/var/lib/openbao"
  "/bao-keys"
  "/var/lib/trilium"
  "/var/lib/opengist"
  "/var/lib/open-webui"
  "/var/lib/n8n"
  "/var/lib/nixarr/state"
  "/var/lib/containers"  # Podman/container state
];
```

#### O001 (Gateway)

```nix
environment.persistence."/persist".directories = [
  # Add to minimal template:
  "/var/lib/vaultwarden"
  "/var/lib/postgresql"
  "/var/lib/fail2ban"
];
```

#### L001 (Headscale)

```nix
environment.persistence."/persist".directories = [
  # Add to minimal template:
  "/var/lib/headscale"
];
```

#### H003 (Router)

```nix
environment.persistence."/persist".directories = [
  # Add to minimal template:
  "/var/lib/AdGuardHome"
  "/var/lib/dnsmasq"
];

environment.persistence."/persist".files = [
  # Add to minimal template:
  "/boot/keyfile_nvme0n1p1"  # LUKS key - CRITICAL
];
```

---

## Rollout Strategy

### Phase 1: Lowest Risk (VPS Hosts)

Start with L001 and O001:
- Easy to rebuild from scratch if something goes wrong
- Smaller state footprint
- Good practice before tackling complex hosts

**L001 Steps:**
1. Back up `/var/lib/headscale/`
2. Add impermanence module
3. Test on spare VPS first
4. Migrate

**O001 Steps:**
1. Back up Vaultwarden and PostgreSQL
2. Add impermanence module
3. Test carefully (Vaultwarden is critical!)

### Phase 2: Router (H003)

H003 is medium complexity:
- Relatively small state
- But critical for network (test during maintenance window)
- LUKS keyfile needs special handling

### Phase 3: Complex Host (H001)

H001 is most complex due to:
- Multiple containerized services
- Database state in containers
- Many stateful applications

**Approach:**
1. Inventory all state paths (see backup docs)
2. Test with snapshot before committing
3. Gradual rollout with extensive persistence list
4. May need to persist more than expected initially

### Phase 4: NAS (H002) - Maybe Skip

H002 may not benefit from impermanence:
- Primary purpose is persistent data storage
- bcachefs replication already provides redundancy
- Impermanence adds complexity without clear benefit

---

## Filesystem Options

### Option A: bcachefs with Subvolumes (Like Juni)

**Pros:**
- Flexible, modern
- Built-in snapshots
- Replication support

**Setup:**
```nix
fileSystems = {
  "/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "bcachefs";
    options = [ "subvol=@root" ];
  };
  "/nix" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "bcachefs";
    options = [ "subvol=@nix" ];
  };
  "/persist" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "bcachefs";
    options = [ "subvol=@persist" ];
    neededForBoot = true;
  };
};
```

### Option B: BTRFS with Subvolumes

Similar to bcachefs but more mature:

```nix
# Reset @root on boot
boot.initrd.postDeviceCommands = lib.mkAfter ''
  mkdir -p /mnt
  mount -o subvol=/ /dev/disk/by-label/nixos /mnt
  btrfs subvolume delete /mnt/@root
  btrfs subvolume create /mnt/@root
  umount /mnt
'';
```

### Option C: tmpfs Root

Simplest but uses RAM:

```nix
fileSystems."/" = {
  device = "none";
  fsType = "tmpfs";
  options = [ "defaults" "size=2G" "mode=755" ];
};
```

**Best for:** VPS hosts with limited disk but adequate RAM.

---

## Troubleshooting

### Service Fails After Reboot

```bash
# Check what's missing
journalctl -xeu servicename

# Common fixes:
# 1. Add /var/lib/servicename to persistence
# 2. Ensure directory permissions are correct
# 3. Check if service expects specific files in /etc
```

### "No such file or directory" Errors

```bash
# Find what's missing
journalctl -b | grep "No such file"

# Add missing paths to persistence
```

### Slow Boot (Too Many Bind Mounts)

If you have many persisted paths, consider:
1. Consolidating related paths
2. Using symlinks instead of bind mounts for some paths
3. Persisting parent directories instead of many children

### Container State Issues

Containers may have their own state directories:

```nix
# For NixOS containers
environment.persistence."/persist".directories = [
  "/var/lib/nixos-containers"
];

# For Podman
environment.persistence."/persist".directories = [
  "/var/lib/containers/storage/volumes"
  # NOT overlay - that's regenerated
];
```

---

## Tooling Improvements

### Automated Discovery Script

Create a helper that runs periodically to detect unpersisted changes:

```bash
#!/usr/bin/env bash
# /usr/local/bin/impermanence-check

# Get list of persisted paths
PERSISTED=$(nix eval --raw '.#nixosConfigurations.hostname.config.environment.persistence."/persist".directories' 2>/dev/null | tr -d '[]"' | tr ' ' '\n')

# Find modified files outside persisted paths
find / -xdev -type f -mmin -60 2>/dev/null | while read -r file; do
  is_persisted=false
  for path in $PERSISTED; do
    if [[ "$file" == "$path"* ]]; then
      is_persisted=true
      break
    fi
  done
  if ! $is_persisted; then
    echo "UNPERSISTED: $file"
  fi
done
```

### Pre-Reboot Check

Add to your workflow:

```bash
# Before rebooting
bcache-impermanence diff  # or custom script

# Review changes, add to persistence if needed, then reboot
```

---

## Action Items

### Immediate
- [ ] Document all state paths for each host (see backup docs)
- [ ] Create shared impermanence module in flake

### Phase 1 (L001/O001)
- [ ] Back up current state
- [ ] Add impermanence to L001
- [ ] Test thoroughly
- [ ] Roll out to O001

### Phase 2 (H003)
- [ ] Plan maintenance window
- [ ] Add impermanence to H003
- [ ] Verify LUKS key persistence

### Phase 3 (H001)
- [ ] Complete state inventory
- [ ] Test with extensive persistence list
- [ ] Gradual rollout
