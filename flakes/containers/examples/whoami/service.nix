# Example podman service. Copy this directory to flakes/containers/<name>/
# and set `host` to use it.
{
  name = "whoami";
  kind = "podman";
  description = "traefik/whoami test server";
  host = null;
  persist = { data = "/data"; };
  podman = {
    image = "docker.io/traefik/whoami:v1.10";
    ports = [ "18080:80" ]; # 127.0.0.1:18080 on the host
    environment = { WHOAMI_NAME = "boxes"; };
  };
  nginx = ''
    server {
      listen @OVERLAY_IP@:80;
      server_name whoami.joshuabell.xyz;
      location / { proxy_pass http://127.0.0.1:18080; }
    }
  '';
}
