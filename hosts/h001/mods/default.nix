{
  constants,
  lib,
  ...
}:
{
  imports = [
    # The media stack runs in the `arr` floating container (containers/arr).
    ./arr-nginx.nix
    ./hardware-transcoding.nix
    # sec + zitadel run in floating containers (containers/{sec,zitadel}).
    # ./vault.nix
    ./restic-backup.nix
  ];
}
