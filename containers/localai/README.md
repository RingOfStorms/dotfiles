# localai (joe)

LocalAI on joe's RTX 3080 (10 GB) behind one OpenAI-compatible API. Handles
whatever mix of image, TTS, text-chat and 3D models you install. Replaced
Forge and kokoro-tts.

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

List what is installed and what the gallery offers:

```sh
ssh root@joe podman exec localai /local-ai models list
```

Fit on 10 GB is the main constraint. Quantized / GGUF weights and smaller
diffusers pipelines work; full-size bf16 pipelines get moved wholesale to the
GPU by the diffusers backend and OOM. Check the weights size plus the KV cache
or projector before installing.

`LOCALAI_SINGLE_ACTIVE_BACKEND` + 15 min idle unload: one model in VRAM at a
time; switching between modalities reloads (a few seconds).

## Disk cleanup

Everything LocalAI generates — images, TTS wavs, 3D GLBs, videos, whether it
came from the web UI, Open WebUI, life or a script — is written to
`persist.images` (`/tmp/generated` in the container,
`/srv/containers/localai/images` on joe) and treated as scratch space. joe's
`localai-cleanup` timer (`hosts/joe/localai-cleanup.nix`) deletes files older
than 24 h every night at 04:15. Save anything you want to keep at generation
time (download it, or write the b64/URL out yourself).

```sh
ssh root@joe systemctl list-timers localai-cleanup
ssh root@joe journalctl -u localai-cleanup --since -7d
ssh root@joe systemctl start localai-cleanup    # run now
```

Chat history is not on this filesystem, so the sweep does not touch it: the
LocalAI web UI keeps it in browser storage, and Open WebUI has its own
database in `containers/open-webui`.

## Text chat (LLM)

```sh
curl -s http://100.64.0.12:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"hi"}]}' | jq -r '.choices[0].message.content'
```

Per-model config lives in `/srv/containers/localai/models/<model>.yaml`.
Gallery installs overwrite hand edits, so re-apply them after
`models install` and `systemctl restart fleet-localai` to pick up changes.

Sizing notes for 10 GB:

```yaml
context_size: 32768
cache_type_k: q8_0      # f16 KV needs ~4.8 GB at 32k and OOMs
cache_type_v: q8_0
```

Quantizing the KV cache roughly halves it; dropping the context is the other
lever. Some chat models are thinking models: replies carry a `reasoning` field,
and a low `max_tokens` can spend the whole budget on reasoning and return empty
`content` — give them 700+ tokens.

Open WebUI: pick the model in the dropdown; the base URL is already configured.

Large MoE models that exceed 10 GB can still run with `gpu_layers` set below
"all", offloading the remainder to CPU — fine when only a few billion params
are active per token.

## Images

```sh
curl -s http://joe:8080/v1/images/generations -H 'Content-Type: application/json' \
  -d '{"model":"<model>","prompt":"a lighthouse at dusk","size":"1024x1024","response_format":"b64_json"}' \
  | jq -r '.data[0].b64_json' | base64 -d > out.png
```

Without `b64_json` the reply is a `http://localhost:8080/generated-images/…`
URL; replace `localhost` with `joe`.

Open WebUI: Admin → Settings → Images → engine OpenAI, base URL above, plus the
model name.

## Text-to-speech

```sh
curl -s http://joe:8080/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model":"<model>","input":"hello","voice":"<voice>"}' -o t.wav
```

`voice` accepts:
- a built-in name (backend-specific)
- an **equal** mix, comma-separated: `voice_a,voice_b`
- a path to a voice tensor: `/models/kokoro-voices/<name>.pt`

Weighted mixes (Kokoro-FastAPI's `voice_a(1.2)+voice_b(1)` syntax) are not
supported by LocalAI, so precompute them. `models/kokoro-voices/` holds the 67
v1.0 Kokoro voice packs from the old kokoro-fastapi image plus `mix.py`:

```sh
ssh root@joe 'py=$(podman exec localai readlink -f /backends/cuda12-kokoro)/venv/bin/python;
  podman exec localai $py /models/kokoro-voices/mix.py my_voice voice_a=1.2 voice_b=1'
# then use "voice": "/models/kokoro-voices/my_voice.pt"
```

`af_mix.pt` is the blend used most with the old service.

Open WebUI: Admin → Settings → Audio → TTS engine OpenAI, base URL above,
model name and voice (a built-in name or `/models/kokoro-voices/<name>.pt`).

## 3D (image → GLB)

TRELLIS.2 via the `trellis2cpp` backend. On 10 GB LocalAI auto-installs the
**geometry-only** variant (~7 GB, no textures). Image only, no text prompt:
make the image with an image model first (single object, plain background).

```sh
cnt online localai && ssh root@joe podman exec localai /local-ai models install <model>
ssh root@joe systemctl restart fleet-localai   # else "backend not found: trellis2cpp"
printf '{"model":"<model>","image":"%s","quality":"512","response_format":"b64_json"}' \
  "$(base64 -w0 in.png)" | curl -s http://100.64.0.12:8080/3d/generations \
  -H 'Content-Type: application/json' -d @- | jq -r '.data[0].b64_json' | base64 -d > out.glb
```

Web UI: Studio → 3D tab (preview, remesh slider, GLB download).
