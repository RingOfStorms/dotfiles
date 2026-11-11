{
  description = "Reusable OMP coding-agent modules for NixOS hosts";

  inputs = {
    omp.url = "github:can1357/oh-my-pi";
  };
  outputs =
    { self, omp, ... }:
    {
      # The NixOS module installs OMP; user configuration remains local.
      nixosModules.default =
        { config, lib, ... }:
        let
          cfg = config.ringofstorms.omp;
        in
        {
          imports = [ omp.nixosModules.default ];

          options.ringofstorms.omp.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Install and configure the OMP coding agent.";
          };

          config = lib.mkIf cfg.enable {
            programs.omp.enable = true;
            home-manager.sharedModules = [ self.homeManagerModules.default ];
          };
        };
      homeManagerModules.default =
        { config, lib, pkgs, ... }:
        let
          cfg = config.ringofstorms.omp;
        in
        {
          imports = [ omp.homeManagerModules.default ];

          options.ringofstorms.omp.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable OMP for this Home Manager user.";
          };

          config = lib.mkIf cfg.enable {
            programs.omp.enable = true;

            # Preserve files previously managed by Home Manager before its
            # link cleanup removes them. Never touch user-owned files or links.
            home.activation.ompLocalConfig = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
              migrateOmpFile() {
                local name="$1" target="$HOME/.omp/agent/$1" link tmp
                [[ -L "$target" ]] || return 0
                link="$(readlink "$target")"
                case "$link" in
                  ${builtins.storeDir}/*-home-manager-files/.omp/agent/"$name") ;;
                  *) return 0 ;;
                esac

                tmp="$(mktemp "$HOME/.omp/agent/.$name.XXXXXXXX")"
                if [[ "$name" == mcp.json ]]; then
                  # The old Blender entry used a versioned store path that can
                  # be garbage-collected; the system package is on PATH.
                  if ! ${lib.getExe pkgs.jq} '
                    .mcpServers.blender.command? as $cmd |
                    if ($cmd | type) == "string" then
                      if ($cmd | test("^/nix/store/[a-z0-9]+-blender-mcp-[^/]+/bin/blender-mcp$"))
                      then .mcpServers.blender.command = "blender-mcp" else . end
                    else . end
                  ' "$target" > "$tmp"; then
                    rm -f "$tmp"
                    return 1
                  fi
                elif ! cat "$target" > "$tmp"; then
                  rm -f "$tmp"
                  return 1
                fi
                chmod 600 "$tmp"
                mv -fT "$tmp" "$target"
              }

              run migrateOmpFile models.yml
              run migrateOmpFile mcp.json
            '';
          };
        };
    };
}
