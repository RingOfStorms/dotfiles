{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      # Utilities
      inherit (nixpkgs) lib;
      # Define the systems to support (all Linux systems exposed by nixpkgs)
      systems = lib.intersectLists lib.systems.flakeExposed lib.platforms.linux;
      forAllSystems = lib.genAttrs systems;
      # Create a mapping from system to corresponding nixpkgs : https://nixos.wiki/wiki/Overlays#In_a_Nix_flake
      nixpkgsFor = forAllSystems (system: nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};

          mod_worktrees = pkgs.writeShellScriptBin "mod_worktrees" ''
            # Get all local and remote mod_* branches, removing lines with '+'
            branches=$(git branch -a | grep -E 'mod_' | grep -v '^\s*+' | sed 's/^[* ]*//; s/^remotes\/origin\///')

            # Remove duplicates and sort
            branches=$(echo "$branches" | sort -u)

            for branch in $branches; do
                # Skip master or other non-mod branches
                if [[ ! "$branch" =~ ^mod_ ]]; then
                    continue
                fi

                # Derive module name (remove mod_ prefix)
                module_name="''${branch#mod_}"
                module_path="modules/$module_name"

                # Check if worktree already exists
                if [ ! -d "$module_path" ]; then
                    echo "Adding worktree for $branch in $module_path"
                    git worktree add "$module_path" "$branch" 2>/dev/null
                # else
                #     echo "Worktree for $branch already exists"
                fi
            done
          '';
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              mod_worktrees
              deploy-rs
            ];

            shellHook = ''
              if [ -z "''${SKIP_MOD_WORKTREES:-}" ]; then
                mod_worktrees
              fi
            '';
          };
        }
      );

    };
}
