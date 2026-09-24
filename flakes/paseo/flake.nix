{
  description = "Patched Paseo, nono, and a NixOS module for a sandboxed Paseo container";

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
      # - procps on PATH: the daemon shells out to `ps` to kill provider process
      #   trees (tree-kill) and to reconcile managed helpers. Without it a
      #   systemd unit with a minimal PATH crashes the worker (uncaught
      #   `spawn ps ENOENT`) whenever it stops a provider server.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          upstream = paseo.packages.${system};
          patched = upstream.paseo.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./patches/per-worktree-nono.patch
              ./patches/ship-node-pty-prebuild.patch
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
        in
        {
          default = patched;
          paseo = patched;
          desktop = upstream.desktop;
          nono = rustPkgs.callPackage ./nono.nix {
            rustPlatform = rustPkgs.makeRustPlatform {
              cargo = rustToolchain;
              rustc = rustToolchain;
            };
            src = nono;
            version = nono.shortRev;
          };
        });

      nixosModules = {
        # The upstream services.paseo module, unmodified; the container
        # module imports it inside the guest.
        upstream = paseo.nixosModules.default;
        # Host-side module declaring the Paseo container (options under
        # ringofstorms.paseo); see README.md.
        container = import ./container.nix { inherit self; };
      };

      lib = {
        # Guest module giving the container the host primary user's CLI
        # setup; pass it via ringofstorms.paseo.extraGuestModules.
        toolsModule = import ./tools.nix;
      };

      overlays.default = final: prev: {
        paseo = self.packages.${final.stdenv.hostPlatform.system}.paseo;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
