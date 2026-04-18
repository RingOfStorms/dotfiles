# Headscale DERP configuration notes

## Background

DERP servers are Tailscale's relay fallback for peers that cannot establish
a direct UDP connection (typical when one or both peers are behind symmetric
NAT, restrictive corporate firewalls, or full-tunnel VPNs like
GlobalProtect). When a connection goes through DERP, all traffic between
the two peers is encrypted end-to-end but flows through the relay.

By default, Tailscale clients pick the **lowest-latency** DERP region from
the derpmap. Headscale (via `derp.urls`) by default fetches the upstream
Tailscale derpmap (`https://controlplane.tailscale.com/derpmap/default`),
which contains ~30 public regions. Our embedded region (`headscale`,
region_id 999) is added on top.

## Why this matters

Tailscale's public DERP servers are **bandwidth-limited** (~10 Mbit/s per
peer is the documented soft cap on free tailnets). Our self-hosted DERP on
`l001` (Linode Chicago) has no artificial cap.

Several of our peers can never establish a direct connection:

- `t` (work MacBook): GlobalProtect full-tunnel, symmetric NAT
  (`MappingVariesByDestIP: true`). Forced to DERP for everything.
- `joe`, `juni`: behind various NATs, often relayed.

For these peers, DERP throughput is the actual bottleneck for any traffic
between them and the rest of the tailnet.

## Region latencies (from `lio`, measured 2026-04-18)

```
ord:        14.4ms (Chicago)        public
headscale:  17.7ms (Chicago, ours)  self-hosted
tor:        25.3ms (Toronto)        public
nyc:        30.7ms                  public
iad:        30.9ms                  public
den:        37.2ms                  public
... (others further)
```

The headscale Linode lives in `ORD` (Chicago) so it's only ~3ms slower than
Tailscale's `ord` region from US-Central peers. That's why peers naturally
gravitate to `ord` instead of our embedded region under default config.

## Options we considered

### Option A — `RegionScore` bias (NOT POSSIBLE with stock headscale)

Tailscale's `tailcfg.DERPMap.HomeParams.RegionScore` is a per-region
latency multiplier. Setting `RegionScore[999] = 0.5` would tell clients
to treat headscale's measured latency as half of actual, biasing
selection toward us while preserving public DERPs as failover.

**Blocker:** headscale's `mergeDERPMaps()` (in `hscontrol/derp/derp.go`)
explicitly only copies the `Regions` map and discards `HomeParams`. Even
if we provide a JSON file with `HomeParams.RegionScore`, headscale strips
it before serving the derpmap to clients. This would require patching
headscale (~10 lines of Go, applied via Nix overlay) — viable but
maintenance burden.

### Option B — Filter out nearby public regions

Serve a static derpmap file via `derp.paths` that contains the upstream
derpmap minus nearby regions (drop `ord`, `tor`, optionally `nyc`/`iad`).
With those gone, `headscale` becomes the lowest-latency region and is
selected as preferred. Distant regions remain as failover.

**Drawback:** requires maintaining a JSON snapshot of the upstream
derpmap (or a periodic fetch+filter script). Stale when Tailscale adds
or moves regions. Adds operational complexity.

### Option C — Self-hosted DERP only **(chosen)**

Set `derp.urls = []` and `derp.auto_update_enable = false`. Headscale
serves only our embedded region (999) to clients. Clients have no choice
but to use it for all relayed traffic.

**Pros:**
- Zero JSON/derpmap files to maintain.
- All relayed traffic goes through infra we control (no bandwidth cap).
- Simplest possible configuration.

**Cons:**
- If `l001` goes offline, all DERP-dependent peers lose connectivity to
  each other. (Direct connections still work where possible.)
- No geographic redundancy for peers in distant regions.

## Why Option C for now

- Simplicity is worth more than the failover. If `l001` goes down,
  several other things break too — DERP is not the binding constraint
  on our overall availability.
- Avoiding manual derpmap JSON files keeps this configuration entirely
  declarative in nix.
- Easy to revisit: if we hit availability issues, we can switch to
  Option B (filtered public DERPs as failover) or invest in Option A
  (patch headscale for `RegionScore`).

## Revisit triggers

Reconsider this config if any of:

- `l001` outages start affecting peer-to-peer connectivity in noticeable
  ways for relayed pairs (`t` <-> anything, etc.).
- We add peers in geographically distant regions (EU/Asia) where the
  Chicago-only DERP adds significant relay latency.
- A future headscale release adds first-class `RegionScore` support
  (this would unblock Option A without patching).
