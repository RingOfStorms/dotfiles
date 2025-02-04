{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  rustChannel = config.programs.rust.channel;
  rustVersion = config.programs.rust.version;
in
{
  options.components.rust = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Rust programming language support.";
    };

    repl = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the evcxr repl for `rust` command.";
    };

    channel = mkOption {
      type = types.str;
      default = "stable";
      description = "The Rust release channel to use (e.g., stable, beta, nightly).";
    };

    version = mkOption {
      type = types.str;
      default = "latest";
      description = "The specific version of Rust to use. Use 'latest' for the latest stable release.";
    };
  };

  config = mkIf config.components.rust.enable {
    environment.systemPackages = with pkgs; [
      rustup gcc
    ] ++ (if config.components.rust.repl then [ pkgs.evcxr ] else [ ]);

    environment.shellAliases = mkIf config.components.rust.repl {
      rust = "evcxr";
    };
  };
}
