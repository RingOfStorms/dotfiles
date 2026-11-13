# Test service (nixos kind): stock nginx welcome page, nothing else.
# Twin of ../hello-podman; practise deploy/stop/expose, or enable backups for move tests.
{
  name = "hello-nixos";
  kind = "nixos";
  description = "test: nginx splash page in an nspawn container";

  # Test markers are disposable. Restore-based moves require backups enabled.
  backup.enable = false;

  # Unused by nginx; test markers survive local restarts only while backups
  # are disabled. Enable backups explicitly before testing a stateful move.
  persist = {
    data = "/data";
  };

  # Host network: nginx in the container listens on 127.0.0.1:8081 only. The
  # host nginx serves https://hello-nixos.joshuabell.xyz/ on the tailnet,
  # gated by the fleet oauth2-proxy (sso-proxy on h005). Widen it for a
  # while with `cnt expose hello-nixos.web --exposure public --for 15m`.
  routes.web = {
    port = 8081;
    exposure = "tailnet";
    auth = "oauth2-proxy";
  };
}
