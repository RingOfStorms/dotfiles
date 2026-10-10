# image-gen (LocalAI on joe) — replaces Forge

Goal: a pre-made image generation server with an API, no UI to babysit.
LocalAI gives an OpenAI-compatible `POST /v1/images/generations`, so Open
WebUI and coding agents talk to it like the OpenAI images API.

## Deploy

1. Rebuild joe once with `hosts/joe/containers.nix` (host module, NVIDIA CDI,
   persisted `/srv/containers` etc.). Push first: joe pulls the containers
   flake from git.
2. Copy kept Forge files (below), then `cnt deploy image-gen`.
3. Install a model: web UI at http://joe:8080 → Models, or
   `sudo podman exec image-gen local-ai models install flux.2-klein-4b`.
4. Test:
   ```sh
   curl http://joe:8080/v1/images/generations -H 'Content-Type: application/json' \
     -d '{"model":"flux.2-klein-4b","prompt":"a red fox in snow","size":"1024x1024"}'
   ```
5. Open WebUI: Admin → Settings → Images → engine "OpenAI", base URL
   `http://100.64.0.12:8080/v1`, any API key, model name as installed.

## Model picks for an RTX 3080 (10 GB)

| Model | Why |
|---|---|
| `flux.2-klein-4b` | Fast (4 steps), good quality, also image editing. Start here. |
| `z-image-turbo-diffusers` | Strong photoreal + text in images; tight on 10 GB. |
| `flux.1-dev-ggml` | Flux 1 dev, quantized; reuses the Forge encoders below. Non-commercial license. |

`LOCALAI_SINGLE_ACTIVE_BACKEND` + 15 min idle unload keep VRAM free for
games and Kokoro when idle.

## What to keep from Forge (`joe:/var/lib/forge`, 15 GB)

| Path (under `storage/stable_diffusion/models/`) | Size | Keep? |
|---|---|---|
| `lora/loraflux.TA_trained.safetensors` | 19 MB | **Yes**, your own trained Flux LoRA; not downloadable. |
| `vae/ae.safetensors` | 320 MB | Optional: same sha256 as LocalAI's flux.1-dev-ggml file, saves a download. |
| `clip/clip_l.safetensors` | 235 MB | Optional, same as gallery. |
| `clip/t5xxl_fp16.safetensors` | 9.2 GB | Optional, same as gallery (big download otherwise). |
| `clip/t5xxl_fp8_e4m3fn.safetensors` | 4.6 GB | No, duplicate of fp16. |
| `ckpt/` | empty | No Flux/SD checkpoint was ever installed. |
| `stable-diffusion-webui-forge/log/images/` | 1 image + log.csv | Your only generation; keep if you care. |
| everything else (app code, venv, `home/`, ui-config) | ~250 MB | No. |

Copy on joe before deploy:

```sh
s=/var/lib/forge/storage/stable_diffusion/models; d=/srv/containers/image-gen/models
sudo install -d $d
sudo cp $s/lora/loraflux.TA_trained.safetensors $s/vae/ae.safetensors \
  $s/clip/clip_l.safetensors $s/clip/t5xxl_fp16.safetensors $d/
sudo cp -r /var/lib/forge/stable-diffusion-webui-forge/log/images ~/forge-outputs
```

Then remove `hosts/joe/forge.nix` and `/var/lib/forge` from joe's
persistence, rebuild, and delete `/persist/var/lib/forge`.
