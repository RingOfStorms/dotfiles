{
  description = "Patched Paseo and nono with a mandatory provider sandbox NixOS module";

  inputs = {
    paseo = {
      url = "github:getpaseo/paseo/135a3b4c9e49a28b9d16ced8fc0e45b4da9fc502";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nono = {
      url = "github:always-further/nono/6118b79aeda1365da213d85457b4d3cf1201d575";
      flake = false;
    };
    # nono needs a newer rustc than nixpkgs ships.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      paseo,
      nixpkgs,
      nono,
      rust-overlay,
      ...
    }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Upstream paseo plus local fixes:
      # - per-worktree-nono patch: every OpenCode agent gets a dedicated server
      #   whose cwd is the agent cwd, so the nono launcher can scope it.
      # - ship-node-pty-prebuild patch: the install closure listed node-pty's
      #   prebuilt pty.node under the root node_modules, but npm installs
      #   node-pty (a @getpaseo/server dependency) under
      #   packages/server/node_modules, so the addon was never copied and the
      #   terminal worker died on startup ("Terminal worker is not running").
      # - mandatory-provider-sandbox patch: OpenCode and OMP default to Nono;
      #   trusted agent profiles can opt out and receive Paseo tools. Custom
      #   providers/plugins and daemon-mediated ACP execution stay disabled.
      # - procps on PATH: the daemon shells out to `ps` to kill provider process
      #   trees (tree-kill) and to reconcile managed helpers. Without it a
      #   systemd unit with a minimal PATH crashes the worker (uncaught
      #   `spawn ps ENOENT`) whenever it stops a provider server.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          upstream = paseo.packages.${system};
          patchedOpencode = pkgs.opencode.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./patches/opencode-config-isolation.patch ];
          });
          patched = upstream.paseo.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./patches/per-worktree-nono.patch
              ./patches/ship-node-pty-prebuild.patch
              ./patches/mandatory-provider-sandbox.patch
            ];
            postFixup = (old.postFixup or "") + ''
              wrapProgram $out/bin/paseo-server \
                --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.procps ]}
            '';
          });
          rustPkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          rustToolchain = rustPkgs.rust-bin.stable.latest.default;
          opencode = patchedOpencode;
        in
        {
          default = patched;
          paseo = patched;
          opencode = patchedOpencode;
          nono = rustPkgs.callPackage ./nono.nix {
            rustPlatform = rustPkgs.makeRustPlatform {
              cargo = rustToolchain;
              rustc = rustToolchain;
            };
            src = nono;
            version = nono.shortRev;
          };
        });

      lib.mkProviderLauncher = { pkgs, nonoPackage ? self.packages.${pkgs.stdenv.hostPlatform.system}.nono }:
        pkgs.writeShellApplication {
          name = "paseo-nono-launch";
          runtimeInputs = [ nonoPackage ];
          text = ''
            if [ "''${PASEO_PROVIDER_SANDBOX_REQUIRED:-}" != 1 ]; then
              echo "paseo-nono-launch: mandatory sandbox flag missing" >&2
              exit 126
            fi
            case "''${PASEO_PROVIDER_ID:-}" in
              opencode) profile="$HOME/.config/nono/profiles/opencode.json"; store_args=(--read /nix/store) ;;
              omp) profile="$HOME/.config/nono/profiles/omp.json"; store_args=() ;;
              *) echo "paseo-nono-launch: invalid or missing provider ID" >&2; exit 126 ;;
            esac
            : "''${HOME:?HOME must be set}"
            cwd="''${PASEO_PROVIDER_CWD:?PASEO_PROVIDER_CWD must be set}"
            case "$cwd" in /*) ;; *) echo "paseo-nono-launch: cwd must be absolute" >&2; exit 126 ;; esac
            if [ ! -d "$cwd" ]; then
              echo "paseo-nono-launch: provider workdir is not a directory: $cwd" >&2
              exit 126
            fi
            if [ ! -r "$profile" ]; then
              echo "paseo-nono-launch: mandatory Nono profile missing or unreadable: $profile" >&2
              exit 126
            fi
            exec ${pkgs.lib.getExe nonoPackage} --silent run --profile "$profile" --workdir "$cwd" "''${store_args[@]}" --allow "$cwd" -- "$@"
          '';
        };

      nixosModules = {
        upstream = paseo.nixosModules.default;
        default = import ./module.nix { inherit self; };
      };

      overlays.default = final: prev: {
        paseo = self.packages.${final.stdenv.hostPlatform.system}.paseo;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

    };
}
