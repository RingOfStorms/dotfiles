{
  description = "Reusable OMP coding-agent modules for NixOS hosts";

  inputs = {
    omp.url = "github:can1357/oh-my-pi";
  };
  outputs =
    { self, omp, ... }:
    {
      # The NixOS module installs OMP and provides the shell aliases. The
      # upstream package remains an implementation detail of this wrapper.
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
        { config, lib, ... }:
        let
          cfg = config.ringofstorms.omp;
        in
        {
          imports = [ omp.homeManagerModules.default ];

          options.ringofstorms.omp = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Enable OMP for this Home Manager user.";
            };
            settings = lib.mkOption {
              type = lib.types.attrs;
              default = {
                modelRoles.default = "litellm/air-gemini-3.8-flash";
                startup.quiet = true;
              };
              description = "OMP settings written by its Home Manager module.";
            };
            modelsFile = lib.mkOption {
              type = lib.types.lines;
              default = ''
                providers:
                  litellm:
                    baseUrl: http://h001.net.joshuabell.xyz:8094/v1
                    api: openai-completions
                    auth: none
                    discovery:
                      type: litellm
                    models:
                      - id: air-gemini-3.8-flash
                        name: air-gemini-3.8-flash
                        contextWindow: 128000
                        maxTokens: 16384
              '';
              description = "YAML model catalog written to ~/.omp/agent/models.yml.";
            };
          };

          config = lib.mkIf cfg.enable {
            programs.omp = {
              enable = true;
              settings = cfg.settings;
            };
            home.file.".omp/agent/models.yml".text = cfg.modelsFile;
          };
        };
    };
}
