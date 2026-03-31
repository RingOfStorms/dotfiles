{
  description = "ports - SSH port forwarding TUI";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = rec {
          ports = pkgs.buildGoModule {
            pname = "ports";
            version = "0.1.0";
            src = ./.;
            vendorHash = "sha256-TUbaUoqDZoQTkcOMtoE/FlAiqkWN+x49JeGkDguh2UU=";
            meta = {
              description = "SSH port forwarding TUI - discover and toggle tunnels interactively";
              mainProgram = "ports";
            };
          };
          default = ports;
        };

        apps = rec {
          ports = {
            type = "app";
            program = "${self.packages.${system}.ports}/bin/ports";
          };
          default = ports;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ go gopls gotools openssh ];
        };
      }
    ) // {
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.ringofstorms.ports;
          portsPkg = self.packages.${pkgs.stdenv.hostPlatform.system}.ports;
        in
        {
          options.ringofstorms.ports = {
            enable = lib.mkEnableOption "ports - SSH port forwarding TUI";
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ portsPkg ];
          };
        };
    };
}
