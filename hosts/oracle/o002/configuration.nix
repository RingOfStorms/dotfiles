{ ... }:
{
  # Allow `ssh -R 0.0.0.0:PORT:...` remote forwards to bind on all
  # interfaces (not just localhost) so tunneled apps are reachable from
  # outside. Without this the 0.0.0.0 bind is silently downgraded to
  # 127.0.0.1. Use `clientspecified` so the client controls the bind
  # address (default is still localhost unless 0.0.0.0 is requested).
  services.openssh.settings.GatewayPorts = "clientspecified";
}
