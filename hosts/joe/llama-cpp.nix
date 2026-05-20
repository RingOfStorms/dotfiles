{
  inputs,
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.llama-cpp;

  # Pinned llama-cpp from a frozen nixpkgs (see hosts/joe/flake.nix input).
  # We import the pinned nixpkgs as its own pkgs set with cudaSupport=true so
  # the resulting llama-cpp derivation hash exactly matches the one already
  # in /nix/store on joe, avoiding a multi-hour from-source CUDA rebuild
  # (which has been crashing the machine). Bumping
  # inputs.llama-cpp-nixpkgs is what triggers a rebuild -- nothing else does.
  pkgsLlamaCpp = import inputs.llama-cpp-nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
    };
  };
in
{
  # Enable CUDA globally on this host so any other package that wants CUDA
  # picks it up. The llama-cpp package itself comes from the pinned pkgs
  # set above, NOT from this host's rolling pkgs, so this flag does not
  # affect llama-cpp's drv hash.
  nixpkgs.config.cudaSupport = true;

  services.llama-cpp = {
    enable = true;
    package = pkgsLlamaCpp.llama-cpp;
    host = "0.0.0.0";
    port = c.port;

    # Router-mode model presets.
    # Models are downloaded from Hugging Face on first request and cached in
    # /var/cache/llama-cpp (LLAMA_CACHE). The router loads/unloads models
    # on demand, capped by --models-max below (mirrors the old
    # OLLAMA_KEEP_ALIVE=0 behavior on a single 24GB GPU).
    # Model picks driven by the r/LocalLLaMA "Best Local LLMs Apr 2026"
    # megathread, filtered to what fits joe (RTX 3080 10GB + 32GB DDR4).
    #
    # IMPORTANT VRAM CONSTRAINT
    # joe runs a KDE Plasma desktop session (kwin/Chrome/Steam) which
    # holds ~2.4 GB of the 10 GB framebuffer. Effective VRAM for llama
    # is ~7.0–7.5 GB, NOT 10 GB. All sizing below assumes 7 GB budget.
    #
    # Settings that apply to BOTH models:
    #   * parallel=1            single-user box; default n_seq_max=4
    #                           quadruples KV cache for no benefit.
    #   * ctx-size=32768        64k blew KV past the 7 GB budget. 32k
    #                           leaves headroom and is plenty for chat.
    #   * ngl=99 (explicit)     `auto` aborts when combined with
    #                           tensor-overrides (n-cpu-moe), then
    #                           silently puts EVERYTHING on the GPU and
    #                           OOMs. Pin layer count by hand.
    #   * cache-type-k/v=q8_0   halves KV cache footprint vs f16, ~zero
    #                           quality cost. Critical on a 10 GB card.
    #   * reasoning=on          replaces the deprecated
    #                           --chat-template-kwargs '{"enable_thinking":true}'.
    #                           litellm flips it off per-call for the
    #                           `-no_think` model variants.
    modelsPreset = {
      # Primary: Gemma 4 26B-A4B (general purpose, multimodal).
      # 26B total / 4B activated. Dense attention layers, MoE FFNs.
      # At Q4_K_XL the file is ~16 GB; with n-cpu-moe=99 only the
      # ~2 GB of attention/embedding stays on GPU, which fits.
      "gemma-4-26b-a4b" = {
        hf-repo = "unsloth/gemma-4-26B-A4B-it-GGUF";
        hf-file = "gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
        alias = "gemma-4-26b-a4b";
        ngl = "99";
        n-cpu-moe = "99"; # send ALL MoE experts to CPU
        ctx-size = "32768";
        parallel = "1";
        flash-attn = "on";
        cache-type-k = "q8_0";
        cache-type-v = "q8_0";
        jinja = "on";
        reasoning = "on"; # `-no_think` variant flips this per-request
        # Sampling per Gemma 4 model card (thread: false79, truthputer).
        temp = "1.0";
        top-p = "0.95";
        top-k = "64";
      };

      # Secondary: Qwen3.5-35B-A3B (agentic coding).
      # 35B total / 3B activated, hybrid SSM+MoE — note this needs an
      # extra "recurrent state cache" GPU buffer on top of normal KV,
      # which is what was OOMing previously.
      "qwen3.5-35b-a3b" = {
        hf-repo = "unsloth/Qwen3.5-35B-A3B-GGUF";
        hf-file = "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf";
        alias = "qwen3.5-35b-a3b";
        ngl = "99";
        n-cpu-moe = "99"; # all 256 experts on CPU; only hot path on GPU
        ctx-size = "32768";
        parallel = "1";
        flash-attn = "on";
        cache-type-k = "q8_0";
        cache-type-v = "q8_0";
        jinja = "on";
        reasoning = "on";
        # Sampling per u/awitod's Qwen3.5-35B-A3B unsloth-guide config.
        temp = "0.7";
        top-p = "0.8";
        top-k = "20";
        min-p = "0.0";
        presence-penalty = "1.5";
      };
    };

    extraFlags = [
      "--models-max"
      "1" # Single GPU — keep at most one model resident at a time.
      "--metrics" # Prometheus-compatible /metrics endpoint.
    ];
  };

  # The upstream services.llama-cpp module uses DynamicUser=true, which
  # creates a per-boot UID under /var/lib/private. That's incompatible with
  # impermanence bind-mounting /var/lib/llama-cpp directly. Force a stable
  # system user so the bind mount works (same pattern as ollama.nix did).
  systemd.services.llama-cpp.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "llama-cpp";
    Group = "llama-cpp";
    StateDirectory = lib.mkForce "llama-cpp";
    CacheDirectory = lib.mkForce "llama-cpp";
  };

  users.users.llama-cpp = {
    isSystemUser = true;
    group = "llama-cpp";
    home = "/var/lib/llama-cpp";
  };
  users.groups.llama-cpp = { };

  # Ensure both state and cache dirs exist with the right ownership before
  # the unit starts (ProtectSystem=strict + ReadWritePaths needs them to
  # exist for mount namespacing).
  systemd.tmpfiles.rules = [
    "d /var/lib/llama-cpp   0750 llama-cpp llama-cpp -"
    "d /var/cache/llama-cpp 0750 llama-cpp llama-cpp -"
  ];

  # Allow access from Tailscale overlay and LAN.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
  networking.firewall.allowedTCPPorts = [ c.port ];
}
