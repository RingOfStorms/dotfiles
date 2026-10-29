# Test service (nixos kind): stock nginx welcome page, nothing else.
# Twin of ../hello-podman; use the pair to practise deploy/stop/move/expose.
{
  name = "hello-nixos";
  kind = "nixos";
  description = "test: nginx splash page in an nspawn container";

  # Where it should run. After `containers move`, update this and push.
  host = "h001";

  # Survives restarts and travels with `move`. Unused by nginx; drop marker
  # files in /srv/containers/hello-nixos/data to see them follow a move.
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
