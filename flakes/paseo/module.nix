{
  config,
  lib,
  paseo,
  pkgs,
  ...
}:
let
  cfg = config.services.paseo;
  upstream = paseo.nixosModules.default;
  launcher = pkgs.writeShellApplication {
    name = "paseo-nono-launch";
    runtimeInputs = [ pkgs.coreutils cfg.nono.package ];
    text = ''
      set -eu
      if [ "''${PASEO_UNSANDBOXED:-0}" = 1 ]; then
        exec "$@"
      fi
      : "''${PASEO_AGENT_CWD:?Paseo did not provide PASEO_AGENT_CWD}"
      exec ${lib.getExe cfg.nono.package} --silent run \
        --profile ${cfg.nono.profile} \
        --workdir "$PASEO_AGENT_CWD" \
        --allow "$PASEO_AGENT_CWD" \
        -- "$@"
    '';
  };
in
{
  imports = [ upstream ];

  options.services.paseo.nono = {
    enable = lib.mkEnableOption "the local Paseo nono integration";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nono;
      defaultText = lib.literalExpression "pkgs.nono";
      description = "nono package used by the launch policy.";
    };
    profile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "paseo-opencode-nono-profile.json" (builtins.toJSON {
        meta = {
          name = "paseo-opencode";
          version = "1";
          description = "Paseo default provider boundary; cwd is granted per launch";
        };
        extends = [ "opencode" ];
        workdir.access = "readwrite";
        environment.allow_vars = [
          "PATH"
          "HOME"
          "USER"
          "LOGNAME"
          "TERM"
          "LANG"
          "LC_*"
          "XDG_*"
          "PASEO_AGENT_*"
          "NO_PROXY"
          "no_proxy"
          "HTTP_PROXY"
          "HTTPS_PROXY"
          "http_proxy"
          "https_proxy"
        ];
      });
      defaultText = lib.literalExpression "pkgs.writeText ...";
      description = "nono profile applied to each provider process by default.";
    };
    optOutProfile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "paseo-unsandboxed-nono-profile.json" (builtins.toJSON {
        meta = {
          name = "paseo-unsandboxed";
          version = "1";
          description = "Explicit opt-out profile; do not use by default";
        };
        extends = [ "default" ];
        workdir.access = "readwrite";
      });
      defaultText = lib.literalExpression "pkgs.writeText ...";
      description = "Profile kept as an explicit opt-out reference.";
    };
  };

  config = lib.mkIf cfg.nono.enable {
    environment.systemPackages = [ launcher cfg.nono.package ];

    systemd.services.paseo = {
      environment = {
        PASEO_NONO_LAUNCHER = lib.getExe launcher;
        PASEO_NONO_PROFILE = toString cfg.nono.profile;
        PASEO_NONO_OPTOUT_PROFILE = toString cfg.nono.optOutProfile;
      };
      path = [ cfg.nono.package launcher ];
    };
  };
}
