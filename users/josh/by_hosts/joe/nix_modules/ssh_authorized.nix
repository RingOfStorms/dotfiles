{ settings, ... }:
{
  users.user.${settings.user.username}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINoBKfj+2SAlTxgdK1jYMFYoTTthX9jvfC+gko1Wlr4L nix2joe"
  ];
}
