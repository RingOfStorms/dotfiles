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

  # Same ids as on h001 bare metal, so the copied files keep working.
  users.users.puzzles.uid = 986;
  users.groups.puzzles.gid = 975;

  services.puzzles-server = {
    enable = true;
    # Build with the guest's nixpkgs so the unfree predicate above applies.
    package = pkgs.callPackage "${puzzles}/nix/package.nix" { };
    # 0.0.0.0 in its private netns (the guest firewall admits 8093 only),
    # 127.0.0.1 if net.private is turned off again.
    settings.http = "${fleetNet.bindAddress}:8093";
  };
}
