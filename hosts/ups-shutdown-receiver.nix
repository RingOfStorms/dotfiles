# Receiver for h005's NUT ups-shutdown (hosts/h005/mods/ups.nix). h005 SSHes
# in as root with a dedicated key whose authorized_keys entry forces
# `fleet-ups-shutdown`, so that key can do nothing but power the host off.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  upsShutdown = pkgs.writeShellApplication {
    name = "fleet-ups-shutdown";
    runtimeInputs = [ pkgs.systemd ];
    text = ''exec /run/current-system/sw/bin/shutdown -h now "UPS battery critical (triggered by h005)"'';
  };
in
{
  options.fleet.upsShutdownPubKey = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = fleet.global.upsShutdownPubKey or null;
    description = "Dedicated SSH public key for h005's NUT ups-shutdown (hosts/h005/mods/ups.nix), restricted to fleet-ups-shutdown.";
  };

  config = {
    environment.systemPackages = [ upsShutdown ];
    users.users.root.openssh.authorizedKeys.keys =
      lib.optional (config.fleet.upsShutdownPubKey != null)
        ''command="/run/current-system/sw/bin/fleet-ups-shutdown",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ${config.fleet.upsShutdownPubKey}'';
  };
}
