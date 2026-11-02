# Trilium notes (notes.joshuabell.xyz). Trilium runs with noAuthentication =
# true; the only way in is the route below, gated by the fleet oauth2-proxy
# (hosts/h005/oauth2-proxy.nix).
{
  name = "trilium";
  kind = "nixos";
  description = "Trilium notes (notes.joshuabell.xyz, behind the fleet oauth2-proxy)";

  persist = {
    data = "/var/lib/trilium"; # document.db (+wal), backups, session secret
    nixos = "/var/lib/nixos";
  };

  # Stopped copies of document.db + its WAL are consistent; no hook needed.

  # Login at sso-proxy.joshuabell.xyz, only zitadel role `notes`. The desktop
  # sync client can't do the browser login.
  net = {
    private = true;
    index = 4;
  };
  # trilium auth is via the fleet oauth2-proxy on h005; the
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
