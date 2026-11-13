# Test service (podman kind): stock nginx welcome page, nothing else.
# Twin of ../hello-nixos; practise deploy/stop, or enable backups for move tests.
{
  name = "hello-podman";
  kind = "podman";
  description = "test: nginx splash page in a podman container";

  # Test markers are disposable. Restore-based moves require backups enabled.
  backup.enable = false;

  # Unused by nginx; test markers survive local restarts only while backups
  # are disabled. Enable backups explicitly before testing a stateful move.
  persist = {
    data = "/data";
  };

  # Published on all addresses and opened in the host firewall at deploy
  # time. http://<host>:8082/
  tcpPorts = [ 8082 ];
  podman = {
    image = "docker.io/library/nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de";
    ports = [ "0.0.0.0:8082:80" ];
  };
}
