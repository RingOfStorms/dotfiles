{ constants, fleet, inputs, pkgs, ... }:
let
  overlayIp = constants.host.overlayIp;
  upstreamPort = constants.services.paseo.port;
  # OpenCode v2.0.18 ships a stale x86_64-linux node_modules hash.
  opencode = inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
  opencodePackage = (opencode.override {
    node_modules = opencode.node_modules.override {
      hash = "sha256-9gJjhes2ueYckAgdeGlPwZcaIDdwB3ZnqK/XHHXhWNs=";
    };
  }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (pkgs.writeText "opencode-optional-plugin-entry.patch" ''
        --- a/packages/plugin/src/host.ts
        +++ b/packages/plugin/src/host.ts
        @@ -24,8 +24,7 @@
                 return resolveModule(specifier, target.directory)
               } catch (error) {
                 if (
        -          !(error instanceof Error) ||
        -          !("code" in error) ||
        +          !error || typeof error !== "object" || !("code" in error) ||
                   ![
                     "ENOENT",
                     "ENOTDIR",
      '')
    ];
    # The upstream Nix expression calls `opencode completion`, removed in v2.
    postInstall = "";
  });
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
    inherit opencodePackage;
    ompPackage = inputs.omp-flake.inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ upstreamPort ];
}
