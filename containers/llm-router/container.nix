# Guest config. ../../containers/llm-router is a stdlib-only Go gateway; it
# needs no runtime deps beyond a CA bundle.
{ pkgs, lib, fleetNet, ... }:
let
  router = pkgs.buildGoModule {
    pname = "llm-router";
    version = "0.1.0";
    src = ./.;
    vendorHash = null; # standard library only
    meta.mainProgram = "llm-router";
  };
in
{
  system.stateVersion = "25.11";

  # Pinned so the device-login token in persist keeps its owner.
  users.users.llm-router = {
    isSystemUser = true;
    uid = 984;
    group = "llm-router";
  };
  users.groups.llm-router.gid = 984;

  systemd.services.llm-router = {
    description = "OpenAI-compatible LLM gateway (air, Copilot, OpenRouter)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe router} --listen ${fleetNet.bindAddress}:8095";
      User = "llm-router";
      Group = "llm-router";
      # persist.data: the Copilot token written by the device login.
      StateDirectory = "llm-router";
      EnvironmentFile = "/var/secrets/litellm.env"; # OPENROUTER_API_KEY
      Restart = "always";
      RestartSec = 5;
      # Streaming completions run for many minutes; give the process room.
      TimeoutStopSec = 30;
      # Catalog fetches and device login talk to the public internet.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
    };
  };
}
