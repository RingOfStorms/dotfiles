{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      ...
    }@inputs:
    let
      # Utilities
      inherit (inputs.nixpkgs) lib;
      fleet = import ./hosts/fleet.nix;

      # Define the systems to support: https://github.com/NixOS/nixpkgs/blob/master/lib/systems/flake-systems.nix
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      # Create a mapping from system to corresponding nixpkgs : https://nixos.wiki/wiki/Overlays#In_a_Nix_flake
      nixpkgsFor = forAllSystems (system: inputs.nixpkgs.legacyPackages.${system});

      # Generate a deploy script for a host from the fleet registry.
      # Hosts with lanIp or specific deploy targets use NIX_SSHOPTS for SSH key auth.
      mkDeployScript = pkgs: name:
        let
          hostDef = fleet.hosts.${name};
          flakePath = hostDef.flakePath or "hosts/${name}";

          # Determine deploy target: prefer lanIp for local hosts, else hostname
          target =
            if hostDef ? lanIp then "root@${hostDef.lanIp}"
            else name;

          # Hosts accessed by name (on tailnet) that already have SSH keys configured
          # don't need NIX_SSHOPTS. Hosts accessed by raw IP do.
          needsKey = hostDef ? lanIp;
          sshOpts =
            if needsKey
            then ''NIX_SSHOPTS="-i ${fleet.global.secretsKeyPath}" ''
            else "";
        in
        pkgs.writeShellScriptBin "deploy_${name}" ''
          ${sshOpts}nixos-rebuild --flake $(git rev-parse --show-toplevel)'/${flakePath}#${name}' --target-host ${target} --use-substitutes --no-reexec switch
        '';

      # Which hosts get deploy scripts (exclude non-deployable entries like 't' and 'l002')
      deployHosts = builtins.attrNames fleet.deployableHosts;

      # Security auditor — scans every flake.lock for stale/off-branch nixpkgs
      # inputs (via DeterminateSystems/flake-checker, fetched at runtime) and
      # matches CVEs against built host closures (via vulnix). The script lives
      # at scripts/audit/audit.sh; this just wraps it with its runtime deps so
      # the toolchain stays scoped to `nix run .#audit` / the devShell and never
      # lands on every machine. See scripts/audit/audit.sh for usage.
      mkAuditApp = pkgs:
        pkgs.writeShellApplication {
          name = "nixos-audit";
          runtimeInputs = [ pkgs.vulnix pkgs.jq pkgs.git pkgs.findutils ];
          text = builtins.readFile ./scripts/audit/audit.sh;
        };
    in
    {
      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          audit = {
            type = "app";
            program = "${mkAuditApp pkgs}/bin/nixos-audit";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            # Per-script tools live in their own sub-flakes so we don't drag
            # a toolchain (Go etc.) onto every machine that just wants
            # deploy_*. The bifrost-models regen script is at
            # scripts/bifrost_models/ — `cd` there and `nix develop` (or
            # let direnv pick up the .envrc).
            packages = map (mkDeployScript pkgs) deployHosts
              ++ [ (mkAuditApp pkgs) ];
          };
        }
      );
    };
}
