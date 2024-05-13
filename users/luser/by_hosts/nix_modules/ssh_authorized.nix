{ settings, ... }:
{
  users.user.${settings.user.username}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJie9OPheWn/EZWfXJSZ3S0DnISqI3ToCmOqhX/Tkwby nix2h002"
  ];
}
