{ pkgs, ... }:
{
  # Allow `ssh -R 0.0.0.0:PORT:...` remote forwards to bind on all
  # interfaces (not just localhost) so tunneled apps are reachable from
  # outside. Without this the 0.0.0.0 bind is silently downgraded to
  # 127.0.0.1. Use `clientspecified` so the client controls the bind
  # address (default is still localhost unless 0.0.0.0 is requested).
  services.openssh.settings.GatewayPorts = "clientspecified";

  # ── Headscale co-host mitigations ───────────────────────────────────
  # o002 runs BOTH the headscale coordination server (headscale.nix) AND
  # tailscaled (it's a tailnet node). This is officially unsupported; these
  # settings make it safe.

  # CRITICAL: do NOT let o002's system DNS route through its own MagicDNS.
  # headscale serves MagicDNS at 100.100.100.100; if o002 used that for its
  # own resolution, a headscale restart/outage would take out o002's DNS and
  # break ACME, nginx upstream resolution, etc. --accept-dns=false keeps
  # o002 on its real upstream resolver. (--login-server is set by the common
  # tailnet module; list flags merge so it is preserved.)
  #
  # GOTCHA (caused a real outage): the NixOS autoconnect script only passes
  # extraUpFlags on (re)auth (BackendState NeedsLogin/Stopped). When tailscaled
  # is already Running, deploying this flag does NOT re-apply it, so o002 sat
  # with CorpDNS=true and resolved everything (including the headscale hostname)
  # via MagicDNS. The oneshot below converges the pref on every activation.
  services.tailscale.extraUpFlags = [ "--accept-dns=false" ];

  systemd.services.tailscale-disable-magicdns = {
    description = "Enforce tailscale --accept-dns=false (co-host must not use its own MagicDNS)";
    after = [ "tailscaled-autoconnect.service" ];
    wants = [ "tailscaled-autoconnect.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale set --accept-dns=false";
    };
  };

  # Co-host DNS shortcut: resolve the headscale hostname to LOOPBACK on o002.
  # tailscaled dials the PUBLIC server_url (https://headscale.joshuabell.xyz)
  # for BOTH the coordination server and the embedded DERP relay. Those run
  # locally on o002, so pointing the name at 127.0.0.1 / ::1 makes o002 reach
  # them directly — avoiding a public-IP hairpin (Oracle's NAT cannot route the
  # instance back to its own floating IP) and any external-DNS dependency. nginx
  # terminates TLS for this vhost on 0.0.0.0:443 and [::]:443 with the real LE
  # cert, so TLS still verifies against the loopback address.
  #
  # This also overrides a stale resolver result: Oracle's VCN resolver
  # (169.254.169.254) still returns the decommissioned l001 Linode IP
  # (172.236.111.33) for this name, whereas public DNS correctly returns o002
  # (164.152.19.60). nsswitch resolves `files` before `dns`, so this wins.
  networking.hosts = {
    "127.0.0.1" = [ "headscale.joshuabell.xyz" ];
    "::1" = [ "headscale.joshuabell.xyz" ];
  };

  # tailscaled connects to the PUBLIC server_url (https://headscale...), so
  # headscale must be up first. Order autoconnect after headscale. (Soft
  # dependency: `wants`, not `requires`, so a headscale hiccup doesn't hard
  # fail the tailnet join — tailscaled retries.)
  systemd.services.tailscaled-autoconnect = {
    after = [ "headscale.service" ];
    wants = [ "headscale.service" ];
  };
}
