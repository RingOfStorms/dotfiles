# llm-router: the fleet's OpenAI-compatible LLM gateway (:8095, private
# network), served at llm.joshuabell.xyz. Candidate LiteLLM replacement,
# deployed *alongside* the litellm container for the trial; clients move over
# once it has proven itself.
{
  name = "llm-router";
  kind = "nixos";
  description = "LLM gateway, trial alongside litellm (llm.joshuabell.xyz)";

  # Device-login state is disposable; re-authenticate after loss.
  backup.enable = false;

  # Copilot device-login token (0600) plus nothing else. The pinned static
  # user preserves it across local restarts; a fresh placement re-authenticates.
  persist = {
    data = "/var/lib/llm-router";
    nixos = "/var/lib/nixos";
  };

  # sec-agent grant on the host (bound read-only in flake.nix); cnt deploy
  # and cnt move refuse a target host that lacks it. The key predates the
  # router: it is the preformatted EnvironmentFile for upstream settings.
  secrets = [ "litellm-env" ];

  net = {
    private = true;
    index = 19;
    # Local LiteLLM-compatible server on the LAN.
    egress = [ "10.12.14.181:9010/tcp" ];
  };

  # Streaming completions: no proxy buffering, long timeouts.
  routes.web = {
    name = "llm";
    group = "AI";
    icon = "https://api.iconify.design/fluent-emoji-flat/locomotive.svg";
    port = 8095;
    exposure = "tailnet";
    auth = "native";
    buffering = false;
    timeouts = "600s";
    extraConfig = ''
      send_timeout 600s;
    '';
  };
}
