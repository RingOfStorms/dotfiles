# Kokoro TTS (text-to-speech), OpenAI-compatible /v1/audio/speech.
# Replaces hosts/joe/kokoro-tts.nix (same image, port and data layout).
# NVIDIA only: the CDI device below fails to start on hosts without the
# nvidia container toolkit.
{
  name = "kokoro-tts";
  kind = "podman";
  description = "Kokoro TTS API (GPU)";
  host = "joe";

  # Copied from joe:/var/lib/kokoro-tts/{models,voices} (owner 1001 = appuser).
  persist = {
    models = "/app/api/src/models";
    voices = "/app/api/src/voices/custom";
  };

  # http://joe:8880/v1/audio/speech, docs at /docs
  tcpPorts = [ 8880 ];
  podman = {
    # Pinned to what joe runs today. v0.9.0(-cu128) exists; check its
    # model/voice paths before bumping.
    image = "ghcr.io/remsky/kokoro-fastapi-gpu:v0.2.4-master";
    ports = [ "0.0.0.0:8880:8880" ];
    environment = {
      USE_GPU = "true";
      PYTHONUNBUFFERED = "1";
      ALLOW_ORIGINS = "*";
    };
    extraArgs = [
      "--device=nvidia.com/gpu=all"
      "--group-add=video"
    ];
  };
}
