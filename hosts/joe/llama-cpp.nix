{
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.llama-cpp;
in
{
  # Enable CUDA globally on this host so pkgs.llama-cpp (and its deps) match
  # the derivation hashes published by https://cuda-maintainers.cachix.org,
  # avoiding multi-hour from-source rebuilds. A per-package `.override` here
  # produces a different drv hash than the cache and forces a local build.
  nixpkgs.config.cudaSupport = true;

  services.llama-cpp = {
    enable = true;
    package = pkgs.llama-cpp;
    host = "0.0.0.0";
    port = c.port;

    # Router-mode model presets.
    # Models are downloaded from Hugging Face on first request and cached in
    # /var/cache/llama-cpp (LLAMA_CACHE). The router loads/unloads models
    # on demand, capped by --models-max below (mirrors the old
    # OLLAMA_KEEP_ALIVE=0 behavior on a single 24GB GPU).
    modelsPreset = {
      # Primary: Qwen3.6 MoE (35B total / 3B activated, vision-capable).
      # NOTE: brand-new architecture — if llama.cpp can't load it, the
      # qwen3-coder fallback below uses the well-supported Qwen3 MoE arch.
      "qwen3.6-35b-a3b" = {
        hf-repo = "unsloth/Qwen3.6-35B-A3B-GGUF";
        hf-file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
        alias = "qwen3.6-35b-a3b";
        ngl = "auto";
        ctx-size = "32768";
        flash-attn = "auto";
        jinja = "on";
        # Thinking-mode sampling recommended by the Qwen3.6 model card.
        temp = "1.0";
        top-p = "0.95";
        top-k = "20";
        min-p = "0.0";
        presence-penalty = "1.5";
      };

      # Fallback: known-working coder MoE (30B total / 3B activated).
      "qwen3-coder-30b-a3b" = {
        hf-repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF";
        hf-file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf";
        alias = "qwen3-coder-30b-a3b";
        ngl = "auto";
        ctx-size = "32768";
        flash-attn = "auto";
        jinja = "on";
      };
    };

    extraFlags = [
      "--models-max"
      "1" # Single 3090 — keep at most one model resident at a time.
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
