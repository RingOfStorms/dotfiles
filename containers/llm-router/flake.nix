{
  description = "llm-router: OpenAI-compatible LLM gateway as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... only the guest follows the current supported stable release.
    guestpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      ...
    }:
    let
      containersLib = import ../lib.nix;
      fleet = import ../../hosts/fleet.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          # Network: service.nix net (private).
          binds = [
            {
              host = "${fleet.global.secretsDir}/litellm-env";
              container = "/var/secrets/litellm.env";
              readOnly = true;
            }
          ];
        };
      };
    });
}
