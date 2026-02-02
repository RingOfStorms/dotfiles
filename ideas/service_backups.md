# Service Backup Strategy

## Overview

This document outlines the backup strategy for the NixOS fleet, covering critical data paths, backup tools, and recovery procedures.

## Current State

**No automated backups are running today.** This is a critical gap.

## Backup Topology

```
┌─────────────────────────────────────────────────────────────┐
│                    BACKUP TOPOLOGY                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   H001,H003,O001,L001 ──────► H002:/data/backups (primary) │
│                        └────► B2/S3 (offsite)              │
│                                                             │
│   H002 (NAS) ───────────────► B2/S3 (offsite only)         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Critical Paths by Host

### L001 (Headscale) - HIGHEST PRIORITY

| Path | Description | Size | Priority |
|------|-------------|------|----------|
| `/var/lib/headscale/` | SQLite DB with all node registrations | Small | CRITICAL |
| `/var/lib/acme/` | SSL certificates | Small | High |

**Impact if lost:** ALL mesh connectivity fails - new connections fail, devices can't rejoin.

### O001 (Oracle Gateway)

| Path | Description | Size | Priority |
|------|-------------|------|----------|
| `/var/lib/vaultwarden/` | Password vault (encrypted) | ~41MB | CRITICAL |
| `/var/lib/postgresql/` | Atuin shell history | ~226MB | Medium |
| `/var/lib/acme/` | SSL certificates | Small | High |

**Impact if lost:** All public access down, password manager lost.

### H001 (Services)

| Path | Description | Size | Priority |
|------|-------------|------|----------|
| `/var/lib/forgejo/` | Git repos + PostgreSQL | Large | CRITICAL |
| `/var/lib/zitadel/` | SSO database + config | Medium | CRITICAL |
| `/var/lib/openbao/` | Secrets vault | Small | CRITICAL |
| `/bao-keys/` | Vault unseal keys | Tiny | CRITICAL |
| `/var/lib/trilium/` | Notes database | Medium | High |
| `/var/lib/opengist/` | Gist data | Small | Medium |
| `/var/lib/open-webui/` | AI chat history | Medium | Low |
| `/var/lib/n8n/` | Workflows | Medium | Medium |
| `/var/lib/acme/` | SSL certificates | Small | High |
| `/var/lib/nixarr/state/` | Media manager configs | Small | Medium |

**Note:** A 154GB backup exists at `/var/lib/forgejo.tar.gz` - this is manual and should be automated.

### H003 (Router)

| Path | Description | Size | Priority |
|------|-------------|------|----------|
| `/var/lib/AdGuardHome/` | DNS filtering config + stats | Medium | High |
| `/boot/keyfile_nvme0n1p1` | LUKS encryption key | Tiny | CRITICAL |

**WARNING:** The LUKS keyfile must be stored separately in a secure location (e.g., Vaultwarden).

### H002 (NAS)

| Path | Description | Size | Priority |
|------|-------------|------|----------|
| `/data/nixarr/media/` | Movies, TV, music, books | Very Large | Low (replaceable) |
| `/data/pinchflat/` | YouTube downloads | Large | Low |

**Note:** bcachefs already has 2x replication. Offsite backup is optional but recommended for irreplaceable data.

## Recommended Backup Tool: Restic

### Why Restic?

- Modern, encrypted, deduplicated backups
- Native NixOS module: `services.restic.backups`
- Multiple backend support (local, S3, B2, SFTP)
- Incremental backups with deduplication
- Easy pruning/retention policies

### Shared Backup Module

Create a shared module at `modules/backup.nix`:

```nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.backup;
in {
  options.my.backup = {
    enable = mkEnableOption "restic backups";
    paths = mkOption { type = types.listOf types.str; default = []; };
    exclude = mkOption { type = types.listOf types.str; default = []; };
    postgresBackup = mkOption { type = types.bool; default = false; };
  };

  config = mkIf cfg.enable {
    # PostgreSQL dumps before backup
    services.postgresqlBackup = mkIf cfg.postgresBackup {
      enable = true;
      location = "/var/backup/postgresql";
      compression = "zstd";
      startAt = "02:00:00";
    };

    services.restic.backups = {
      daily = {
        paths = cfg.paths ++ (optional cfg.postgresBackup "/var/backup/postgresql");
        exclude = cfg.exclude ++ [
          "**/cache/**"
          "**/Cache/**"
          "**/.cache/**"
          "**/tmp/**"
        ];
        
        # Primary: NFS to H002
        repository = "/nfs/h002/backups/${config.networking.hostName}";
        
        passwordFile = config.age.secrets.restic-password.path;
        initialize = true;
        
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
        
        timerConfig = {
          OnCalendar = "03:00:00";
          RandomizedDelaySec = "1h";
          Persistent = true;
        };
        
        backupPrepareCommand = ''
          # Ensure NFS is mounted
          mount | grep -q "/nfs/h002" || mount /nfs/h002
        '';
      };
      
      # Offsite to B2/S3 (less frequent)
      offsite = {
        paths = cfg.paths;
        repository = "b2:joshuabell-backups:${config.networking.hostName}";
        passwordFile = config.age.secrets.restic-password.path;
        environmentFile = config.age.secrets.b2-credentials.path;
        
        pruneOpts = [
          "--keep-daily 3"
          "--keep-weekly 2"
          "--keep-monthly 3"
        ];
        
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
        };
      };
    };
  };
}
```

### Per-Host Configuration

#### L001 (Headscale)
```nix
my.backup = {
  enable = true;
  paths = [ "/var/lib/headscale" "/var/lib/acme" ];
};
```

#### O001 (Oracle)
```nix
my.backup = {
  enable = true;
  paths = [ "/var/lib/vaultwarden" "/var/lib/acme" ];
  postgresBackup = true;  # For Atuin
};
```

#### H001 (Services)
```nix
my.backup = {
  enable = true;
  paths = [
    "/var/lib/forgejo"
    "/var/lib/zitadel"
    "/var/lib/openbao"
    "/bao-keys"
    "/var/lib/trilium"
    "/var/lib/opengist"
    "/var/lib/open-webui"
    "/var/lib/n8n"
    "/var/lib/acme"
    "/var/lib/nixarr/state"
  ];
};
```

#### H003 (Router)
```nix
my.backup = {
  enable = true;
  paths = [ "/var/lib/AdGuardHome" ];
  # LUKS key backed up separately to Vaultwarden
};
```

## Database Backup Best Practices

### For Containerized PostgreSQL (Forgejo/Zitadel)

```nix
systemd.services.container-forgejo-backup = {
  script = ''
    nixos-container run forgejo -- pg_dumpall -U forgejo \
      | ${pkgs.zstd}/bin/zstd > /var/lib/forgejo/backups/db-$(date +%Y%m%d).sql.zst
  '';
  startAt = "02:30:00";  # Before restic runs at 03:00
};
```

### For Direct PostgreSQL

```nix
services.postgresqlBackup = {
  enable = true;
  backupAll = true;
  location = "/var/backup/postgresql";
  compression = "zstd";
  startAt = "*-*-* 02:00:00";
};
```

## Recovery Procedures

### Restoring from Restic

```bash
# List snapshots
restic -r /path/to/repo snapshots

# Restore specific snapshot
restic -r /path/to/repo restore abc123 --target /restore

# Restore latest
restic -r /path/to/repo restore latest --target /restore

# Restore specific path
restic -r /path/to/repo restore latest \
  --target /restore \
  --include /var/lib/postgresql

# Mount for browsing
mkdir /mnt/restic
restic -r /path/to/repo mount /mnt/restic
```

### PostgreSQL Recovery

```bash
# Stop PostgreSQL
systemctl stop postgresql

# Restore from restic
restic restore latest --target / --include /var/lib/postgresql

# Or from SQL dump
sudo -u postgres psql < /restore/all-databases.sql

# Start PostgreSQL
systemctl start postgresql
```

## Backup Verification

Add automated verification:

```nix
systemd.timers.restic-verify = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "weekly";
    Persistent = true;
  };
};

systemd.services.restic-verify = {
  script = ''
    ${pkgs.restic}/bin/restic -r /path/to/repo check --read-data-subset=5%
  '';
};
```

## Monitoring & Alerting

```nix
# Alert on backup failure
systemd.services."restic-backups-daily".serviceConfig.OnFailure = "notify-failure@%n.service";

systemd.services."notify-failure@" = {
  serviceConfig.Type = "oneshot";
  script = ''
    ${pkgs.curl}/bin/curl -X POST https://ntfy.sh/joshuabell-backups \
      -H "Title: Backup Failed" \
      -d "Service: %i on ${config.networking.hostName}"
  '';
};
```

## Action Items

### Immediate (This Week)
- [ ] Set up restic backups for L001 (Headscale) - most critical
- [ ] Back up H003's LUKS keyfile to Vaultwarden
- [ ] Create `/data/backups/` directory on H002

### Short-Term (This Month)
- [ ] Implement shared backup module
- [ ] Deploy to all hosts
- [ ] Set up offsite B2 bucket

### Medium-Term
- [ ] Automated backup verification
- [ ] Monitoring/alerting integration
- [ ] Test recovery procedures
