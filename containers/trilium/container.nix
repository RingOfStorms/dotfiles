# Guest config. Private network: trilium on :9111; only h001's nginx
# (the generated, oauth2-proxy-gated vhost) is reachable from outside.
{ fleetNet, ... }:
{
  system.stateVersion = "24.11";

  # Same ids as on h001 bare metal, so the copied files keep working.
  users.users.trilium.uid = 989;
  users.groups.trilium.gid = 985;

  services.trilium-server = {
    enable = true;
    host = fleetNet.bindAddress;
    port = 9111;
    dataDir = "/var/lib/trilium";
    # Auth is the fleet oauth2-proxy on h005 (nginx auth_request); never
    # expose 9111 directly.
    noAuthentication = true;
    instanceName = "joshuabell";
  };
  systemd.services.trilium-server.environment.TRILIUM_NO_UPLOAD_LIMIT = "true";
}
