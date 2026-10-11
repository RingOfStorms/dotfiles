# Test service (nixos kind): stock nginx welcome page, nothing else.
# Twin of ../hello-podman; use the pair to practise deploy/stop/move.
{
  name = "hello-nixos";
  kind = "nixos";
  description = "test: nginx splash page in an nspawn container";

  # Where it should run. After `containers move`, update this and push.
  host = "lio";

  # Survives restarts and travels with `move`. Unused by nginx; drop marker
  # files in /srv/containers/hello-nixos/data to see them follow a move.
  persist = { data = "/data"; };

  # Host network: nginx in the container listens here; opened in the host
  # firewall at deploy time. http://<host>:8081/
  tcpPorts = [ 8081 ];
}
