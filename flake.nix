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
                    (git worktree add "$module_path" "$branch" 2>/dev/null) &
                else
                    (
                      cd "$module_path"
                      git fetch origin "$branch" >/dev/null 2>&1
                      if ! git diff --quiet HEAD "origin/$branch"; then
                          echo "Updates available for $branch in $module_path"
                          git pull origin "$branch"
                      fi
                      cd - >/dev/null
                    ) &
                fi
            done

            # Wait for all background processes to finish
            wait

            # Check for and remove orphaned module directories
            if [ -d "modules" ]; then
                for dir in modules/*; do
                    if [ -d "$dir" ]; then
                        module_name="$(basename "$dir")"
                        if ! echo "$branches" | grep -q "^mod_$module_name$"; then
                            echo "Removing orphaned module directory: $dir"
                            (git worktree remove --force "$dir") &
                        fi
                    fi
                done
            fi 

            wait
          '';
          mod_status = pkgs.writeShellScriptBin "mod_status" ''
            cwd=$(pwd)
            root=$(git rev-parse --show-toplevel)
            for dir in "$root"/modules/*/; do
                cd "$dir"
                echo
                echo " >> $(basename "$dir"):"
                git status
            done
            cd "$cwd"
          '';
          linode_deploy = pkgs.writeShellScriptBin "linode_deploy" ''
            cwd=$(pwd)
            root=$(git rev-parse --show-toplevel)
            if [ ! -d "$root/hosts/linode/$1" ]; then
              echo "Host $1 does not exist"
              exit 1
            fi
            cd "$root/hosts/linode/$1"
            echo "Deploying $(basename "$(pwd)")..."
            deploy
            cd "$cwd"
          '';
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              mod_worktrees
              mod_status
              linode_deploy
              deploy-rs
            ];

            shellHook = ''
              if [ -z "''${SKIP_MOD_WORKTREES:-}" ]; then
                mod_worktrees &
              fi
            '';
          };
        }
      );

    };
}
