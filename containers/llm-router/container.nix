# Guest config. ./src is a stdlib-only Go gateway; it needs no runtime deps
# beyond a CA bundle.
{ pkgs, lib, fleetNet, ... }:
let
  # nixpkgs currently packages 1.27.3. Keep the latest security patch until
  # the guest input catches up; the source hash is from https://go.dev/dl/.
  go = pkgs.go_1_27.overrideAttrs (old: {
    version = "1.27.4";
    src = pkgs.fetchurl {
      url = "https://go.dev/dl/go1.27.4.src.tar.gz";
      hash = "sha256-c8+4VxrsDAEXdofbhxY9Rqog6XeWcncokaoXZU2aYJk=";
    };
  });
  # Names are public model namespaces; URLs may be supplied by EnvironmentFile.
  upstreams = [
    {
      name = "air";
      type = "litellm";
      base_url_env = "LITELLM_UPSTREAM_URL";
      api_key_env = "na";
    }
    {
      name = "llm";
      type = "litellm";
      base_url_env = "LITELLM_UPSTREAM_URL_2";
      api_key_env = "na";
    }
    {
      name = "copilot";
      type = "copilot";
      base_url = "https://api.githubcopilot.com";
    }
    {
      name = "openrouter";
      type = "openrouter";
      base_url = "https://openrouter.ai/api/v1";
      api_key_env = "OPENROUTER_API_KEY";
    }
  ];
  upstreamConfig = pkgs.writeText "llm-router-upstreams.json" (builtins.toJSON upstreams);
  router = (pkgs.buildGo127Module.override { inherit go; }) {
    pname = "llm-router";
    version = "0.1.0";
    src = ./src;
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
    description = "OpenAI-compatible LLM gateway (LiteLLM, Copilot, OpenRouter)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.COPILOT_TOKEN_FILE = "/var/lib/llm-router/copilot-token";
    environment.LITELLM_UPSTREAM_API_KEY = "na";
    serviceConfig = {
      ExecStart = "${lib.getExe router} --listen ${fleetNet.bindAddress}:8095 --upstreams ${upstreamConfig}";
      User = "llm-router";
      Group = "llm-router";
      # persist.data: the Copilot token written by the device login.
      StateDirectory = "llm-router";
      EnvironmentFile = "/var/secrets/litellm.env"; # Upstream URLs and API keys
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
