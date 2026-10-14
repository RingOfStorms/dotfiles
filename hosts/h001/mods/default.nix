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
    ./sec.nix
    ./homepage-dashboard.nix
    # ./vault.nix
    ./restic-backup.nix
  ];
}
