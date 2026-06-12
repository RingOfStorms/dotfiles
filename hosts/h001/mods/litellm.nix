{
  inputs,
  pkgs,
  constants,
  ...
}:
let
  declaration = "services/misc/litellm.nix";
  nixpkgsLitellm = inputs.litellm-nixpkgs;
  pkgsLitellm = import nixpkgsLitellm {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  c = constants.services.litellm;
in
{
  disabledModules = [ declaration ];
  imports = [ "${nixpkgsLitellm}/nixos/modules/${declaration}" ];
  options = { };
  config = {
    networking.firewall.enable = true;
    # Expose litellm to my overlay network as well
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];

    # Ensure litellm starts after DNS / network-online is up.
    # (copilot models need to reach github; air/azure models reach the t
    # machine on the LAN — no overlay dep anymore.)
    systemd.services.litellm = {
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ];
    };

    services.litellm = {
      enable = true;
      port = c.port;
      host = "0.0.0.0";
      openFirewall = false;
      package = pkgsLitellm.litellm;
      # gives openrouter key
      environmentFile = "/var/lib/openbao-secrets/litellm-env";
      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        GITHUB_COPILOT_TOKEN_DIR = "${c.dataDir}/github_copilot";
        XDG_CONFIG_HOME = "${c.dataDir}/.config";
      };
      settings = {
        environment_variables = {
          LITELLM_PROXY_API_KEY = "na";
        };
        litellm_settings = {
          check_provider_endpoints = true;
          drop_params = true;
          modify_params = true;
          max_request_size_mb = 4000;
          max_response_size_mb = 4000;
        };
        model_list = [
          # OpenRouter — wildcard catch-all. Any model passed as
          # `openrouter/<slug>` is forwarded as-is, regardless of
          # whether litellm knows about it. This works for chat
          # completions but does NOT make models show up in
          # /v1/models, because litellm can only enumerate wildcard
          # providers it has dedicated discovery code for (OpenAI,
          # Anthropic, Gemini, XAI, Fireworks, Vertex, vLLM, Topaz,
          # LiteLLM Proxy). OpenRouter is not in that list, so for
          # any specific OpenRouter model we want to appear in the
          # model picker, add an explicit alias below.
          {
            model_name = "openrouter/*";
            litellm_params = {
              model = "openrouter/*";
            };
          }
        ]
        # OpenRouter explicit aliases — only needed so these show up
        # in /v1/models (i.e. the OpenWebUI model picker). At call
        # time the wildcard above would handle them equally well.
        ++ (builtins.map
          (m: {
            model_name = "openrouter/${m}";
            litellm_params = {
              model = "openrouter/${m}";
            };
          })
          [
            # NB: OpenRouter namespaces its own stealth/alpha models under
            # the literal `openrouter/` vendor, so the slug is
            # `openrouter/owl-alpha` (was bare `owl-alpha`, now 404s). The
            # `openrouter/${m}` wrapper below therefore yields the litellm
            # model `openrouter/openrouter/owl-alpha` — correct: litellm
            # strips the first provider prefix and forwards the rest.
            "openrouter/owl-alpha"
            "google/gemini-2.5-flash-lite"
            "nvidia/nemotron-3-super-120b-a12b:free"
          ]
        )
        # Copilot
        # Probed with: ./scripts/probe-copilot-models.sh --nix
        #
        # Claude / Gemini / Grok models on Copilot Business do NOT support the
        # /responses endpoint — only /chat/completions. Tagging them with
        # `mode = "chat"` tells litellm to bridge MVA's /v1/responses requests
        # down to /chat/completions upstream instead of forwarding 1:1 (which
        # gets a 400 "unsupported_api_for_model" from githubcopilot).
        ++ (builtins.map
          (m: let
            # responses-only: codex variants and gpt-5.4+ (incl. 5.5, 5.6, …).
            # GitHub Copilot rejects /chat/completions for these with
            # "unsupported_api_for_model"; they only speak /responses.
            isResponsesOnly =
              (builtins.match ".*codex.*" m != null)
              || (builtins.match "gpt-5\\.[4-9].*" m != null);
            # chat-only on Copilot: claude-*, gemini-*, grok-*, embeddings
            isChatOnly =
              (builtins.match "claude-.*" m != null)
              || (builtins.match "gemini-.*" m != null)
              || (builtins.match "grok-.*" m != null)
              || (builtins.match "text-embedding-.*" m != null)
              || (m == "trajectory-compaction");
          in {
            model_name = "copilot-${m}";
            litellm_params = {
              model = "github_copilot/${m}";
              # NB: do NOT set extra_headers here. Recent litellm
              # (get_copilot_default_headers + GithubCopilotResponsesAPIConfig)
              # already injects copilot-integration-id, editor-version,
              # editor-plugin-version, user-agent, x-github-api-version, etc.
              # Adding our own with different casing (Copilot-Integration-Id vs
              # copilot-integration-id) causes httpx to emit BOTH header
              # lines, which GitHub concatenates and rejects as
              # "unknown Copilot-Integration-Id". Copilot-Vision-Request and
              # X-Initiator are also computed per-request automatically.
            };
          } // (
            if isResponsesOnly then { model_info.mode = "responses"; }
            else if isChatOnly then { model_info.mode = "chat"; }
            else {}
          ))
          [
            "claude-haiku-4.5"
            "claude-opus-4.5"
            "claude-opus-4.6"
            "claude-opus-4.7"
            "claude-opus-4.8"
            "claude-sonnet-4.5"
            "claude-sonnet-4.6"
            "gemini-2.5-pro"
            "gemini-3.5-flash"
            "gpt-3.5-turbo"
            "gpt-3.5-turbo-0613"
            "gpt-4"
            "gpt-4-0125-preview"
            "gpt-4-0613"
            "gpt-4-o-preview"
            "gpt-4.1"
            "gpt-4.1-2025-04-14"
            "gpt-41-copilot"
            "gpt-4o"
            "gpt-4o-2024-05-13"
            "gpt-4o-2024-08-06"
            "gpt-4o-2024-11-20"
            "gpt-4o-mini"
            "gpt-4o-mini-2024-07-18"
            "gpt-5-mini"
            "gpt-5.3-codex"
            "gpt-5.4"
            "gpt-5.4-mini"
            "gpt-5.5"
            "text-embedding-3-small"
            "text-embedding-3-small-inference"
            "text-embedding-ada-002"
            "trajectory-compaction"
          ]
        )
        # 宙 Proxy
        ++ (builtins.map
          (m: {
            model_name = "air-${m}";
            litellm_params = {
              model = "litellm_proxy/${m}";
              api_base = "http://10.12.14.181:9010/air_prd";
              api_key = "na";
              drop_params = true;
              # TODO try this instead of sanitized name
              # additional_drop_params = if [ "messages[*].cacheControl" ];
            };
          })
          # curl -L t:9010/air_prd/models | jq '.data.[].id'
          [
            "claude-3.7-sonnet"
            "claude-haiku-4.5"
            "claude-opus-4"
            "claude-opus-4.1"
            "claude-opus-4.5"
            "claude-opus-4.6"
            "claude-opus-4-7"
            "claude-opus-4.7"
            "claude-opus-4-8"
            "claude-opus-4.8"
            "claude-sonnet-4"
            "claude-sonnet-4.5"
            "claude-sonnet-4-6"
            "claude-sonnet-4.6"
            "codex-auto-review"
            "deepseek-3.1"
            "gemini-2.0-flash"
            "gemini-2.0-flash-lite"
            "gemini-2.5-flash"
            "gemini-2.5-flash-image"
            "gemini-2.5-flash-lite"
            "gemini-2.5-pro"
            "gemini-2.5-pro-batch"
            "gemini-2.5-pro-passthrough"
            "gemini-3.1-flash-lite"
            "gemini-3.1-flash-lite-passthrough"
            "gemini-3.5-flash"
            "gemini-3.5-flash-passthrough"
            "gemini-embedding-001"
            "gemini-embedding-2"
            "glm-4.7"
            "glm-5"
            "gpt-4.1"
            "gpt-4.1-mini"
            "gpt-4o"
            "gpt-4o-applied-ai"
            "gpt-4o-mini"
            "gpt-5"
            "gpt-5-batch"
            "gpt-5-mini"
            "gpt-5-nano"
            "gpt-5.1"
            "gpt-5.2"
            "gpt-5.4"
            "gpt-5.4-mini"
            "gpt-5.4-nano"
            "gpt-5.5"
            "gpt-oss-120b"
            "kimi-2.5"
            "kimi-k2.6"
            "minimax-2.5"
            "o3-mini"
            "o4-mini"
            "text-embedding-005"
            "text-embedding-3-large"
            "text-embedding-3-small"
            "text-embedding-ada-002"
            "text-embedding-large-exp-03-07"
          ]
        )
        # llama.cpp router on joe (RTX 3080 10GB) — models are configured
        # in hosts/joe/llama-cpp.nix (modelsPreset) and downloaded from
        # Hugging Face on first request. The router loads/unloads as
        # needed (max 1 resident model). OpenAI-compatible API at /v1.
        #
        # Per-model defaults (sampling, parallel_tool_calls, thinking
        # toggle) are baked in here so clients don't have to know them.
        # Anything a client sends overrides these defaults.
        #
        # Each upstream model is exposed TWICE in the model list:
        #   local-<model>            -> thinking ON  (default, CoT)
        #   local-<model>-no_think   -> thinking OFF (snappy chat)
        # Clients just pick the variant they want from the model list;
        # nothing else in the request needs to change.
        ++ (
          let
            joeBase = upstream: {
              model = "openai/${upstream}";
              api_base = "http://100.64.0.12:11434/v1";
              api_key = "na";
            };
            # Build a (thinking-on, thinking-off) pair for one upstream.
            mkPair = { name, upstream, sampling }: [
              {
                model_name = "local-${name}";
                litellm_params = joeBase upstream // sampling // {
                  extra_body = {
                    chat_template_kwargs = { enable_thinking = true; };
                  };
                };
                model_info.mode = "chat";
              }
              {
                model_name = "local-${name}-no_think";
                litellm_params = joeBase upstream // sampling // {
                  extra_body = {
                    chat_template_kwargs = { enable_thinking = false; };
                  };
                };
                model_info.mode = "chat";
              }
            ];
          in
          # Gemma 4 26B-A4B — general purpose / multimodal daily driver.
          # Sampling per Gemma 4 model card.
          (mkPair {
            name = "gemma-4-26b-a4b";
            upstream = "gemma-4-26b-a4b";
            sampling = {
              temperature = 1.0;
              top_p = 0.95;
              top_k = 64;
            };
          })
          # Qwen3.5-35B-A3B — agentic coding. Unsloth-recommended sampling
          # per u/awitod's config in the LocalLLaMA Apr 2026 megathread.
          # presence_penalty=1.5 is non-default and materially reduces
          # tool-call loops, so we pin it. parallel_tool_calls=true lets
          # the model emit multiple tool_calls in a single assistant turn
          # instead of one-at-a-time round trips — critical for agents.
          ++ (mkPair {
            name = "qwen3.5-35b-a3b";
            upstream = "qwen3.5-35b-a3b";
            sampling = {
              temperature = 0.7;
              top_p = 0.8;
              top_k = 20;
              presence_penalty = 1.5;
              parallel_tool_calls = true;
            };
          })
        );
      };
    };
  };
}
