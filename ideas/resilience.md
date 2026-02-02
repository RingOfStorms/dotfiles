# Infrastructure Resilience & Failover

## Overview

This document covers strategies for eliminating single points of failure and improving infrastructure resilience.

## Current Architecture

```
                    INTERNET
                        │
              ┌─────────┴─────────┐
              │                   │
        ┌─────▼─────┐      ┌──────▼──────┐
        │   O001    │      │    L001     │
        │  (Oracle) │      │   (Linode)  │
        │  nginx    │      │  Headscale  │
        │  +vault   │      │   (SPOF!)   │
        │  +atuin   │      └──────┬──────┘
        │  (SPOF!)  │             │
        └─────┬─────┘             │
              │         Tailscale Mesh
              │       ┌───────────┴───────────┐
              │       │                       │
        ┌─────▼───────▼─────┐          ┌──────▼──────┐
        │       H001        │          │    H003     │
        │  (Service Host)   │          │   (Router)  │
        │  Forgejo,Zitadel, │          │  AdGuard,   │
        │  LiteLLM,Trilium, │          │  DHCP,NAT   │
        │  NixArr,OpenWebUI │          │   (SPOF!)   │
        └─────────┬─────────┘          └─────────────┘
                  │ NFS
        ┌─────────▼─────────┐
        │       H002        │
        │   (NAS - bcachefs)│
        │  Media, Data      │
        └───────────────────┘
```

## Critical Single Points of Failure

| Host | Service | Impact if Down | Recovery Time |
|------|---------|----------------|---------------|
| **L001** | Headscale | ALL mesh connectivity | HIGH - must restore SQLite exactly |
| **O001** | nginx/Vaultwarden | All public access, password manager | MEDIUM |
| **H003** | DNS/DHCP/NAT | Entire LAN offline | MEDIUM |
| **H001** | All services | Services down but recoverable | MEDIUM |
| **H002** | NFS | Media unavailable | LOW - bcachefs has replication |

---

## Reverse Proxy Resilience (O001)

### Current Problem

O001 is a single point of failure for all public traffic:
- No public access to any service if it dies
- DNS still points to it after failure
- ACME certs are only on that host

### Solution Options

#### Option A: Cloudflare Tunnel (Recommended Quick Win)

**Pros:**
- No single server dependency
- Run `cloudflared` on multiple hosts (H001 as backup)
- Automatic failover between tunnel replicas
- Built-in DDoS protection
- No inbound ports needed

**Cons:**
- Cannot stream media (Jellyfin) - violates Cloudflare ToS
- Adds latency
- Vendor dependency

**Implementation:**

```nix
# On BOTH O001 (primary) AND H001 (backup)
services.cloudflared = {
  enable = true;
  tunnels."joshuabell" = {
    credentialsFile = config.age.secrets.cloudflared.path;
    ingress = {
      "chat.joshuabell.xyz" = "http://100.64.0.13:80";
      "git.joshuabell.xyz" = "http://100.64.0.13:80";
      "notes.joshuabell.xyz" = "http://100.64.0.13:80";
      "sec.joshuabell.xyz" = "http://100.64.0.13:80";
      "sso.joshuabell.xyz" = "http://100.64.0.13:80";
      "n8n.joshuabell.xyz" = "http://100.64.0.13:80";
      "blog.joshuabell.xyz" = "http://100.64.0.13:80";
    };
  };
};
```

Cloudflare automatically load balances across all active tunnel replicas.

#### Option B: DNS Failover with Health Checks

Use Cloudflare DNS with health checks:
- Point `joshuabell.xyz` to both O001 and a backup
- Cloudflare removes unhealthy IPs automatically
- Requires Cloudflare paid plan for load balancing

#### Option C: Tailscale Funnel

Expose services directly without O001:

```bash
# On H001
tailscale funnel 443
```

Exposes H001 directly at `https://h001.net.joshuabell.xyz`

**Pros:**
- No proxy needed
- Per-service granularity
- Automatic HTTPS

**Cons:**
- Uses `ts.net` domain (no custom domain)
- Limited to ports 443, 8443, 10000

#### Option D: Manual Failover with Shared Config

Keep H001 ready to take over O001's role:
1. Same nginx config via shared NixOS module
2. Use DNS-01 ACME challenge (certs work on any host)
3. Update DNS when O001 fails

### Recommended Hybrid Approach

```
┌─────────────────────────────────────────────────────────────┐
│                   RECOMMENDED TOPOLOGY                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Cloudflare DNS (health-checked failover)                 │
│          │                                                  │
│   ┌──────┴──────┐                                          │
│   │             │                                          │
│   ▼             ▼                                          │
│  O001   ──OR── H001 (via Cloudflare Tunnel)               │
│  nginx         cloudflared backup                          │
│                                                             │
│   Jellyfin: Direct via Tailscale Funnel (bypasses O001)   │
│   Vaultwarden: Cloudflare Tunnel (survives O001 failure)  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Changes:**
1. Move Vaultwarden to Cloudflare Tunnel (survives O001 outage)
2. Jellyfin via Tailscale Funnel (no Cloudflare ToS issues)
3. Other services via Cloudflare Tunnel with H001 as backup

---

## Headscale HA (L001)

### The Problem

L001 running Headscale is the MOST CRITICAL SPOF:
- If Headscale dies, existing connections keep working temporarily
- NO NEW devices can connect
- Devices that reboot cannot rejoin the mesh
- Eventually all mesh connectivity degrades

### Solution Options

#### Option 1: Frequent Backups (Minimum Viable)

```nix
my.backup = {
  enable = true;
  paths = [ "/var/lib/headscale" "/var/lib/acme" ];
};
```

**Recovery time:** ~30 minutes to spin up new VPS + restore

#### Option 2: Warm Standby

- Run second Linode/VPS with Headscale configured but stopped
- Daily rsync of `/var/lib/headscale/` to standby
- Update DNS to point to standby if primary fails

```bash
# Daily sync to standby
rsync -avz l001:/var/lib/headscale/ standby:/var/lib/headscale/
```

**Recovery time:** ~5 minutes (start service, update DNS)

#### Option 3: Headscale HA with LiteFS

Headscale doesn't natively support HA, but you can use:
- **LiteFS** for SQLite replication
- **Consul** for leader election and failover

See: https://gawsoft.com/blog/headscale-litefs-consul-replication-failover/

**Recovery time:** ~15 seconds automatic failover

#### Option 4: Use Tailscale Commercial

Let Tailscale handle the control plane HA:
- They manage availability
- Keep Headscale for learning/experimentation
- Critical services use Tailscale commercial

### Recommendation

Start with Option 1 (backups) immediately, work toward Option 2 (warm standby) within a month.

---

## Router HA (H003)

### The Problem

H003 is the network gateway:
- AdGuard Home (DNS filtering)
- dnsmasq (DHCP)
- NAT firewall
- If it dies, entire LAN loses connectivity

### Solution Options

#### Option 1: Secondary DNS/DHCP

Run backup DNS on another host (H001 or H002):
- Secondary AdGuard Home instance
- Clients configured with both DNS servers
- DHCP failover is trickier (consider ISC DHCP with failover)

#### Option 2: Keepalived for Router Failover

If you have two devices that could be routers:

```nix
services.keepalived = {
  enable = true;
  vrrpInstances.router = {
    state = "MASTER";  # or "BACKUP" on secondary
    interface = "eth0";
    virtualRouterId = 1;
    priority = 255;  # Lower on backup
    virtualIps = [{ addr = "10.12.14.1/24"; }];
  };
};
```

#### Option 3: Router Redundancy via ISP

- Use ISP router as fallback gateway
- Clients get two gateways via DHCP
- Less control but automatic failover

### Recommendation

Run secondary AdGuard Home on H001/H002 as minimum redundancy. Full router HA is complex for homelab.

---

## NFS HA (H002)

### Current State

H002 uses bcachefs with 2x replication across 5 disks. Single host failure still causes data unavailability.

### Options

#### Option 1: NFS Client Resilience

Configure NFS clients to handle server unavailability gracefully:

```nix
fileSystems."/nfs/h002" = {
  device = "100.64.0.3:/data";
  fsType = "nfs4";
  options = [
    "soft"           # Don't hang forever
    "timeo=50"       # 5 second timeout
    "retrans=3"      # 3 retries
    "nofail"         # Don't fail boot if unavailable
  ];
};
```

#### Option 2: Second NAS with GlusterFS

For true HA, run two NAS nodes with GlusterFS replication:

```
H002 (bcachefs) ◄──── GlusterFS ────► H00X (bcachefs)
```

**Overkill for homelab**, but an option for critical data.

### Recommendation

Current bcachefs replication is adequate. Focus on offsite backups for truly irreplaceable data.

---

## Recommended Implementation Order

### Phase 1: Quick Wins (This Week)
1. [ ] Set up Cloudflare Tunnel on O001 AND H001
2. [ ] Enable Tailscale Funnel for Jellyfin
3. [ ] Automated backups for L001 Headscale

### Phase 2: Core Resilience (This Month)
4. [ ] DNS-01 ACME for shared certs
5. [ ] Warm standby for Headscale
6. [ ] Secondary AdGuard Home

### Phase 3: Full Resilience (Next Quarter)
7. [ ] Headscale HA with LiteFS (if needed)
8. [ ] Automated failover testing
9. [ ] Runbook documentation

---

## Monitoring & Alerting

Essential for knowing when to failover:

```nix
# Uptime monitoring for critical services
services.uptime-kuma = {
  enable = true;
  # Monitor: Headscale, nginx, Vaultwarden, AdGuard
};

# Or use external monitoring (BetterStack, Uptime Robot)
```

Alert on:
- Headscale API unreachable
- nginx health check fails
- DNS resolution fails
- NFS mount fails
