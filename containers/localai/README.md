# localai (joe)

LocalAI on joe's RTX 3080 (10 GB): image generation and text-to-speech
behind one OpenAI-compatible API. Replaced Forge and kokoro-tts.

- Web UI: http://100.64.0.12:8080 (chat, images, TTS, model gallery)
- API base: `http://100.64.0.12:8080/v1` (no API key; tailnet only, not on the LAN)

## Deploy / models

No internet by default (`internet = false`). Open it for downloads:

```sh
cnt online localai            # 30 min; --for 2h, or --off to close early
cnt deploy localai
ssh root@joe podman exec localai /local-ai models install <name>
ssh root@joe systemctl restart fleet-localai   # CLI installs need a restart to show up
```

Access also ends if the container restarts or the firewall reloads (fail closed).
Installs from the web UI's Models page show up without a restart.

| Model | Status |
|---|---|
| `flux.2-klein-4b` | Installed, tested: 1024² in ~11 s. Also edits images. |
| `kokoro` | Installed, tested. |
| `flux.1-dev-ggml` | Should fit (quantized GGUF); untested. Non-commercial license. |
| `z-image-turbo-diffusers`, `flux.1-schnell` | **No.** Full-size diffusers weights (6B bf16 / 12B); v4.11.0 diffusers backend moves the whole pipeline to the GPU → OOM on 10 GB. |

`LOCALAI_SINGLE_ACTIVE_BACKEND` + 15 min idle unload: one model in VRAM at a
time; switching image ↔ TTS reloads (a few seconds).

## Images

```sh
curl -s http://joe:8080/v1/images/generations -H 'Content-Type: application/json' \
  -d '{"model":"flux.2-klein-4b","prompt":"a lighthouse at dusk","size":"1024x1024","response_format":"b64_json"}' \
  | jq -r '.data[0].b64_json' | base64 -d > out.png
```

Without `b64_json` the reply is a `http://localhost:8080/generated-images/…`
URL; replace `localhost` with `joe`.

Open WebUI: Admin → Settings → Images → engine OpenAI, base URL above,
model `flux.2-klein-4b`.

## Text-to-speech (Kokoro)

Same Kokoro-82M model as the old kokoro-tts service.

```sh
curl -s http://joe:8080/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","input":"hello","voice":"af_heart"}' -o t.wav
```

`voice` accepts:
- a built-in name: `af_heart`, `af_bella`, `bm_lewis`, …
- an **equal** mix, comma-separated: `af_bella,af_heart`
- a path to a voice tensor: `/models/kokoro-voices/<name>.pt`

Weighted mixes (Kokoro-FastAPI's `af_bella(1.2)+af_heart(1)` syntax) are
not supported by LocalAI, so precompute them. `models/kokoro-voices/` holds
the 67 v1.0 voice packs from the old kokoro-fastapi image (it includes
voices like `af_jadzia` that are not on Hugging Face) plus `mix.py`:

```sh
ssh root@joe 'py=$(podman exec localai readlink -f /backends/cuda12-kokoro)/venv/bin/python;
  podman exec localai $py /models/kokoro-voices/mix.py my_voice af_bella=1.2 af_heart=1'
# then use "voice": "/models/kokoro-voices/my_voice.pt"
```

`af_mix.pt` is the blend used most with the old service:
`af_bella(1.2)+af_nicole(0.5)+af_jadzia(0.8)+af_heart(1)`.

Open WebUI: Admin → Settings → Audio → TTS engine OpenAI, base URL above,
model `kokoro`, voice `/models/kokoro-voices/af_mix.pt` (or a name).

Other TTS models in the gallery (untested): `qwen3-tts-*`, `vibevoice`,
`chatterbox`, `fish-speech-s2-pro`.

## 3D (image → GLB)

`trellis2-4b` (TRELLIS.2 via `trellis2cpp`). On 10 GB LocalAI auto-installs the
**geometry-only** variant (~7 GB, no textures). Tested: 512 quality, 1024²
input → 158 MB GLB in ~90 s. Image only, no text prompt: make the image with
`flux.2-klein-4b` first (single object, plain background).

```sh
cnt online localai && ssh root@joe podman exec localai /local-ai models install trellis2-4b
ssh root@joe systemctl restart fleet-localai   # else "backend not found: trellis2cpp"
printf '{"model":"trellis2-4b","image":"%s","quality":"512","response_format":"b64_json"}' \
  "$(base64 -w0 in.png)" | curl -s http://100.64.0.12:8080/3d/generations \
  -H 'Content-Type: application/json' -d @- | jq -r '.data[0].b64_json' | base64 -d > out.glb
```

Web UI: Studio → 3D tab (preview, remesh slider, GLB download).
