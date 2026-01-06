{
  inputs = {
    beszel-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      beszel-nixpkgs,
      ...
    }:
    {
      nixosModules = {
        hub = { ... }: { };
        agent =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            declaration = "services/monitoring/beszel-agent.nix";
            nixpkgs = beszel-nixpkgs;
            beszelPkgs = import nixpkgs {
              system = pkgs.stdenv.hostPlatform.system;
            };
          in
          {
            disabledModules = [ declaration ];
            imports = [ "${nixpkgs}/nixos/modules/${declaration}" ];
            options.beszelAgent = {
              listen = lib.mkOption {
                type = lib.types.str;
                default = "[::]:45876";
                description = "The listen:port address for agent";
              };
              token = lib.mkOption {
                type = lib.types.str;
                description = "The token for agent";
              };
              key = lib.mkOption {
                type = lib.types.str;
                description = "The public key for hub";
                default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDcAr8fbW4XyfL/tCMeMtD+Ou/FFywCNfsHdyvYs3qXf";
              };
              hub = lib.mkOption {
                type = lib.types.str;
                description = "The hub url";
                default = "http://100.64.0.13:8090";
              };
              extraFilesystems = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                description = "The EXTRA_FILESYSTEMS variable value";
                default = null;
              };
            };
            config = {
              services.beszel.agent = {
                package = beszelPkgs.beszel;
                enable = true;
                environment = {
                  SYSTEM_NAME = config.networking.hostName;
                  LISTEN = config.beszelAgent.listen;
                  HUB_URL = config.beszelAgent.hub;
                  TOKEN = config.beszelAgent.token;
                  KEY = config.beszelAgent.key;
                  EXTRA_FILESYSTEMS = lib.mkIf (
                    config.beszelAgent.extraFilesystems != null
                  ) config.beszelAgent.extraFilesystems;
                };
              };

              systemd.services.beszel-agent = {
                requires = [ "tailscaled" ];
                after = [ "tailscaled" ];
              };
            };
          };
      };
    };
}
