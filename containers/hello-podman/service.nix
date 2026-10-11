# Test service (podman kind): stock nginx welcome page, nothing else.
# Twin of ../hello-nixos; use the pair to practise deploy/stop/move.
{
  name = "hello-podman";
  kind = "podman";
  description = "test: nginx splash page in a podman container";

  # Where it should run. After `containers move`, update this and push.
  host = "lio";

  # Survives restarts and travels with `move`. Unused by nginx; drop marker
  # files in /srv/containers/hello-podman/data to see them follow a move.
  persist = { data = "/data"; };

  # Published on all addresses and opened in the host firewall at deploy
  # time. http://<host>:8082/
  tcpPorts = [ 8082 ];
  podman = {
    image = "docker.io/library/nginx:1.29-alpine";
    ports = [ "0.0.0.0:8082:80" ];
  };
}
