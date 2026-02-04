# Migrating Services Between Hosts

## Overview

This document covers procedures for migrating services between NixOS hosts with minimal downtime.

## General Migration Strategy

### Pre-Migration Checklist

- [ ] New host is configured in flake with identical service config
- [ ] New host has required secrets (agenix/sops)
- [ ] Network connectivity verified (Tailscale IP assigned)
- [ ] Disk space sufficient on new host
- [ ] Backup of current state completed

### Migration Types

| Type | Downtime | Complexity | Use When |
|------|----------|------------|----------|
| Cold migration | 5-30 min | Low | Simple services, maintenance windows |
| Warm migration | 2-5 min | Medium | Most services |
| Hot migration | <1 min | High | Databases with replication |

---

## Cold Migration (Simple)

Best for: Stateless or rarely-accessed services.

### Steps

```bash
# 1. Stop service on old host
ssh oldhost 'systemctl stop myservice'

# 2. Copy state to new host
rsync -avz --progress oldhost:/var/lib/myservice/ newhost:/var/lib/myservice/

# 3. Start on new host
ssh newhost 'systemctl start myservice'

# 4. Update reverse proxy (if applicable)
# Edit nginx config: proxyPass = "http://<new-tailscale-ip>"
# Rebuild: ssh proxy 'nixos-rebuild switch'

# 5. Verify service works

# 6. Clean up old host (after verification period)
ssh oldhost 'rm -rf /var/lib/myservice'
```

**Downtime:** Duration of rsync + service start + proxy update.

---

## Warm Migration (Recommended)

Best for: Most services with moderate state.

### Strategy

1. Sync state while service is running (initial sync)
2. Stop service briefly for final sync
3. Start on new host
4. Update routing

### Steps

```bash
# 1. Initial sync (service still running)
rsync -avz --progress oldhost:/var/lib/myservice/ newhost:/var/lib/myservice/

# 2. Stop service on old host
ssh oldhost 'systemctl stop myservice'

# 3. Final sync (quick - only changes since initial sync)
rsync -avz --progress oldhost:/var/lib/myservice/ newhost:/var/lib/myservice/

# 4. Start on new host
ssh newhost 'systemctl start myservice'

# 5. Update reverse proxy immediately
ssh proxy 'nixos-rebuild switch'

# 6. Verify
curl https://myservice.joshuabell.xyz
```

**Downtime:** 2-5 minutes (final rsync + start + proxy switch).

---

## Hot Migration (Database Services)

Best for: PostgreSQL, critical services requiring near-zero downtime.

### PostgreSQL Logical Replication

#### On Source (Old Host)

```nix
services.postgresql = {
  settings = {
    wal_level = "logical";
    max_replication_slots = 4;
    max_wal_senders = 4;
  };
};

# Add replication user
services.postgresql.ensureUsers = [{
  name = "replicator";
  ensurePermissions."ALL TABLES IN SCHEMA public" = "SELECT";
}];
```

#### Set Up Replication

```sql
-- On source: Create publication
CREATE PUBLICATION my_pub FOR ALL TABLES;

-- On target: Create subscription
CREATE SUBSCRIPTION my_sub
  CONNECTION 'host=oldhost dbname=mydb user=replicator'
  PUBLICATION my_pub;
```

#### Cutover

```bash
# 1. Verify replication is caught up
# Check lag on target:
SELECT * FROM pg_stat_subscription;

# 2. Stop writes on source (maintenance mode)

# 3. Wait for final sync

# 4. Promote target (drop subscription)
DROP SUBSCRIPTION my_sub;

# 5. Update application connection strings

# 6. Update reverse proxy
```

**Downtime:** <1 minute (just the cutover).

---

## Service-Specific Procedures

### Forgejo (Git Server)

**State locations:**
- `/var/lib/forgejo/data/` - Git repositories, LFS
- `/var/lib/forgejo/postgres/` - PostgreSQL database
- `/var/lib/forgejo/backups/` - Existing backups

**Procedure (Warm Migration):**

```bash
# 1. Put Forgejo in maintenance mode (optional)
ssh h001 'touch /var/lib/forgejo/data/maintenance'

# 2. Backup database inside container
ssh h001 'nixos-container run forgejo -- pg_dumpall -U forgejo > /var/lib/forgejo/backups/pre-migration.sql'

# 3. Initial sync
rsync -avz --progress h001:/var/lib/forgejo/ newhost:/var/lib/forgejo/

# 4. Stop container
ssh h001 'systemctl stop container@forgejo'

# 5. Final sync
rsync -avz --progress h001:/var/lib/forgejo/ newhost:/var/lib/forgejo/

# 6. Start on new host
ssh newhost 'systemctl start container@forgejo'

# 7. Update O001 nginx
# Change: proxyPass = "http://100.64.0.13" → "http://<new-ip>"
ssh o001 'nixos-rebuild switch'

# 8. Verify
git clone https://git.joshuabell.xyz/test/repo.git

# 9. Remove maintenance mode
ssh newhost 'rm /var/lib/forgejo/data/maintenance'
```

**Downtime:** ~5 minutes.

### Zitadel (SSO)

**State locations:**
- `/var/lib/zitadel/postgres/` - PostgreSQL database
- `/var/lib/zitadel/backups/` - Backups

**Critical notes:**
- SSO is used by other services - coordinate downtime
- Test authentication after migration
- May need to clear client caches

**Procedure:** Same as Forgejo.

### Vaultwarden (Password Manager)

**State locations:**
- `/var/lib/vaultwarden/` - SQLite database, attachments

**Critical notes:**
- MOST CRITICAL SERVICE - users depend on this constantly
- Prefer hot migration or schedule during low-usage time
- Verify emergency access works after migration

**Procedure:**

```bash
# 1. Enable read-only mode (if supported)

# 2. Sync while running
rsync -avz --progress o001:/var/lib/vaultwarden/ newhost:/var/lib/vaultwarden/

# 3. Quick cutover
ssh o001 'systemctl stop vaultwarden'
rsync -avz --progress o001:/var/lib/vaultwarden/ newhost:/var/lib/vaultwarden/
ssh newhost 'systemctl start vaultwarden'

# 4. Update DNS/proxy immediately

# 5. Verify with mobile app and browser extension
```

**Downtime:** 2-3 minutes (coordinate with users).

### Headscale

**State locations:**
- `/var/lib/headscale/` - SQLite database with node registrations

**Critical notes:**
- ALL mesh connectivity depends on this
- Existing connections continue during migration
- New connections will fail during downtime

**Procedure:**

```bash
# 1. Backup current state
restic -r /backup/l001 backup /var/lib/headscale --tag pre-migration

# 2. Sync to new VPS
rsync -avz --progress l001:/var/lib/headscale/ newvps:/var/lib/headscale/

# 3. Stop on old host
ssh l001 'systemctl stop headscale'

# 4. Final sync
rsync -avz --progress l001:/var/lib/headscale/ newvps:/var/lib/headscale/

# 5. Start on new host
ssh newvps 'systemctl start headscale'

# 6. Update DNS
# headscale.joshuabell.xyz → new IP

# 7. Verify
headscale nodes list
tailscale status

# 8. Test new device joining
```

**Downtime:** 5-10 minutes (include DNS propagation time).

### AdGuard Home

**State locations:**
- `/var/lib/AdGuardHome/` - Config, query logs, filters

**Critical notes:**
- LAN DNS will fail during migration
- Configure backup DNS on clients first

**Procedure:**

```bash
# 1. Add temporary DNS to DHCP (e.g., 1.1.1.1)
# Or have clients use secondary DNS server

# 2. Quick migration
ssh h003 'systemctl stop adguardhome'
rsync -avz --progress h003:/var/lib/AdGuardHome/ newhost:/var/lib/AdGuardHome/
ssh newhost 'systemctl start adguardhome'

# 3. Update DHCP to point to new host

# 4. Verify DNS resolution
dig @new-host-ip google.com
```

**Downtime:** 2-3 minutes (clients use backup DNS).

---

## Reverse Proxy Updates

When migrating services proxied through O001:

### Current Proxy Mappings (O001 nginx.nix)

| Domain | Backend |
|--------|---------|
| chat.joshuabell.xyz | 100.64.0.13 (H001) |
| git.joshuabell.xyz | 100.64.0.13 (H001) |
| notes.joshuabell.xyz | 100.64.0.13 (H001) |
| sec.joshuabell.xyz | 100.64.0.13 (H001) |
| sso.joshuabell.xyz | 100.64.0.13 (H001) |
| llm.joshuabell.xyz | 100.64.0.13:8095 (H001) |

### Updating Proxy

1. Edit `hosts/oracle/o001/nginx.nix`
2. Change `proxyPass` to new Tailscale IP
3. Commit and push
4. `ssh o001 'cd /etc/nixos && git pull && nixos-rebuild switch'`

Or for faster updates without commit:

```bash
# Quick test (non-persistent)
ssh o001 'sed -i "s/100.64.0.13/100.64.0.XX/g" /etc/nginx/nginx.conf && nginx -s reload'

# Then update flake and rebuild properly
```

---

## Rollback Procedures

If migration fails:

### Quick Rollback

```bash
# 1. Stop on new host
ssh newhost 'systemctl stop myservice'

# 2. Start on old host (state should still be there)
ssh oldhost 'systemctl start myservice'

# 3. Revert proxy changes
ssh proxy 'nixos-rebuild switch --rollback'
```

### If Old State Was Deleted

```bash
# Restore from backup
restic -r /backup/oldhost restore latest --target / --include /var/lib/myservice

# Start service
systemctl start myservice

# Revert proxy
```

---

## Post-Migration Checklist

- [ ] Service responds correctly
- [ ] Authentication works (if applicable)
- [ ] Data integrity verified
- [ ] Monitoring updated to new host
- [ ] DNS/proxy pointing to new location
- [ ] Old host state cleaned up (after grace period)
- [ ] Backup job updated for new location
- [ ] Documentation updated

---

## Common Issues

### "Permission denied" on New Host

```bash
# Ensure correct ownership
chown -R serviceuser:servicegroup /var/lib/myservice

# Check SELinux/AppArmor if applicable
```

### Service Can't Connect to Database

```bash
# Verify PostgreSQL is running
systemctl status postgresql

# Check connection settings
cat /var/lib/myservice/config.yaml | grep -i database
```

### SSL Certificate Issues

```bash
# Certificates are tied to domain, not host
# Should work automatically if domain unchanged

# If issues, force ACME renewal
systemctl restart acme-myservice.joshuabell.xyz.service
```

### Tailscale IP Changed

```bash
# Get new Tailscale IP
tailscale ip -4

# Update all references to old IP
grep -r "100.64.0.XX" /etc/nixos/
```
