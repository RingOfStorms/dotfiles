{ settings, ... }:
{
  users.users.${settings.user.username}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDa0MUnXwRzHPTDakjzLTmye2GTFbRno+KVs0DSeIPb7 nix2gpdpocket3"
  ];
}
