# Guest config. The module and package come from the puzzles repo flake
# (specialArgs.puzzles).
{
  pkgs,
  lib,
  puzzles,
  fleetNet,
  ...
}:
{
  imports = [ puzzles.nixosModules.default ];
  system.stateVersion = "24.11";

  nixpkgs.config = {
    allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "puzzles" ];
    permittedInsecurePackages = [ "pnpm-9.15.9" ];
  };

  # Pinned ids so the persisted files keep their owner.
  users.users.puzzles.uid = 986;
  users.groups.puzzles.gid = 975;

  services.puzzles-server = {
    enable = true;
    # Build with the guest's nixpkgs so the unfree predicate above applies.
    package = pkgs.callPackage "${puzzles}/nix/package.nix" { };
    # 0.0.0.0 in its private netns (the guest firewall admits 8093 only),
    # 127.0.0.1 without net.private.
    settings.http = "${fleetNet.bindAddress}:8093";
  };
}
