# Trilium notes (notes.joshuabell.xyz). Trilium runs with noAuthentication =
# true; the only way in is the route below, gated by the fleet oauth2-proxy
# (hosts/h005/oauth2-proxy.nix). Tailnet-only since 2026-10-21.
# Was hosts/h001/mods/trilium.nix on bare metal.
{
  name = "trilium";
  kind = "nixos";
  description = "Trilium notes (notes.joshuabell.xyz, behind the fleet oauth2-proxy)";
  host = "h001";

  persist = {
    data = "/var/lib/trilium"; # document.db (+wal), backups, session secret
    nixos = "/var/lib/nixos";
  };

  # Stopped copies of document.db + its WAL are consistent; no hook needed.

  # Gated by the fleet oauth2-proxy on h005 (ROUTING-PLAN §8 step 6): login
  # at sso-proxy.joshuabell.xyz, only zitadel role `notes`. Tailnet-only.
  # The desktop sync client can't do the browser login; it used the old
  # :9112 bypass, removed 2026-10-21.
  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.4.2.
  net = {
    private = true;
    index = 4;
  };
  # Finding M2: trilium auth is via the fleet oauth2-proxy on h005; the
  # guest itself makes no outbound calls.
  internet = false;

  routes.web = {
    port = 9111;
    name = "notes";
    exposure = "tailnet";
    auth = "oauth2-proxy";
    groups = [ "notes" ];
    maxBody = "0"; # TRILIUM_NO_UPLOAD_LIMIT
  };
}
