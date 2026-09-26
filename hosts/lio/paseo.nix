{ constants, fleet, inputs, pkgs, ... }:
let
  overlayIp = constants.host.overlayIp;
  upstreamPort = constants.services.paseo.port;
in
{
  services.paseoBareMetal = {
    enable = true;
    user = constants.host.primaryUser;
    group = "users";
    home = "/home/josh";
    dataDir = "/home/josh/.paseo";
    projects = [ "/home/josh/projects" "/home/josh/other" ];
    catalogWorkdir = "/home/josh/projects";
    uid = 1000;
    worktreesDir = "/home/josh/.paseo/worktrees";
    port = upstreamPort;
    listenAddress = "0.0.0.0";
    extraHostnames = [ overlayIp "${overlayIp}:${toString upstreamPort}" ];
    baseUrl = "http://${overlayIp}:${toString upstreamPort}";
    environmentFile = "${fleet.global.secretsDir}/paseo_agent_env_2026-09-21";
    paseoPackage = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.paseo;
    opencodePackage = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.opencode;
    ompPackage = inputs.omp-flake.inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ upstreamPort ];
}
