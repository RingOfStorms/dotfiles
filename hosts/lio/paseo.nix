# Experimental Paseo execution environment for lio (shared module:
# flakes/paseo). Private and authenticated by default; populate the
# operator-owned secret file and the hand-maintained provider/nono configs in
# /var/lib/paseo (flakes/paseo/README.md) before starting the container.
{
  config,
  constants,
  fleet,
  inputs,
  pkgs,
  ...
}:
let
  c = constants.services.paseo;
in
{
  imports = [ inputs.paseo.nixosModules.container ];

  ringofstorms.paseo = {
    enable = true;
    inherit (c)
      port
      uid
      gid
      dataDir
      projectsDir
      containerIp
      containerIp6
      ;
    hostAddress = "10.0.0.1";
    hostAddress6 = "fc00::1";
    secretFile = "${fleet.global.secretsDir}/paseo_agent_env_2026-09-21";
    extraHostnames = [ constants.host.overlayIp ];
    # Mirror headscale's DNS view (MagicDNS base domain + split domain,
    # hosts/oracle/o002/headscale.nix), so tailnet names such as h001's
    # LiteLLM resolve and bare `h001` expands via the search domain.
    tailnet = {
      enable = true;
      domains = [
        "net.${fleet.global.domain}"
        "~${fleet.global.domain}"
      ];
    };
    ompPackage = inputs.omp-flake.inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.default;
    extraGuestModules = [
      (inputs.paseo.lib.toolsModule {
        inherit (inputs) common ros_neovim;
        hostConfig = config;
        inherit (constants.host) primaryUser;
      })
    ];
  };
}
