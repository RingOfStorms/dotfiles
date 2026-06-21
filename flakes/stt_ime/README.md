# stt_ime - Speech-to-Text Input Method for Fcitx5

Local, privacy-preserving speech-to-text that integrates as a native Fcitx5 input method.

## Components

- **stt-stream**: Rust CLI that captures audio, runs VAD, and transcribes with Whisper
- **fcitx5-stt**: C++ Fcitx5 addon that spawns stt-stream and commits text to apps

## Modes

- **Manual**: Press `Ctrl+Space` or `Ctrl+R` to start/stop recording
- **Oneshot**: Automatically starts on speech, commits on silence, then resets
- **Continuous**: Always listening, commits each utterance automatically

Press `Ctrl+M` while STT is active to cycle between modes.

## Keys (when STT input method is active)

| Key | Action |
|-----|--------|
| `Ctrl+Space` / `Ctrl+R` | Toggle recording (manual mode) |
| `Ctrl+M` | Cycle mode (manual → oneshot → continuous) |
| `Enter` | Accept current preedit text |
| `Escape` | Cancel recording / clear preedit |

## Usage

### NixOS Module

```nix
# In your host's flake.nix inputs:
stt_ime.url = "git+https://git.ros.one/josh/nixos-config?dir=flakes/stt_ime";

# In your NixOS config:
{
  imports = [ inputs.stt_ime.nixosModules.default ];

  ringofstorms.sttIme = {
    enable = true;
    # tiny(.en), base(.en), small(.en), medium(.en), large-v3, large-v3-turbo
    model = "base.en";
    useGpu = false;        # request GPU acceleration at runtime
    # gpuBackend = "hip";  # "cpu" (default) or "hip" (AMD ROCm)

    # Optional UX/accuracy knobs (sensible defaults derive from useGpu):
    # vad = "silero";          # "simple" | "silero" (default: silero on GPU)
    # beamSearch = true;       # more accurate final pass (default: on GPU)
    # vocabulary = "NixOS, fcitx5, kubectl";  # bias toward custom terms
    # removeFillers = false;   # strip "um"/"uh" from transcripts
  };
}
```

On a capable GPU machine, `model = "large-v3-turbo"` with `useGpu = true`
gives near large-v3 accuracy at much lower latency and is the recommended
setup.

### Standalone CLI

```bash
# Run with default settings (manual mode)
stt-stream

# Run in continuous mode
stt-stream --mode continuous

# Use a specific model (dot, dash, or underscore separators all work)
stt-stream --model small.en
stt-stream --model large-v3-turbo

# Higher-accuracy setup (GPU): Silero VAD + beam search + custom vocab
stt-stream --gpu --vad silero --beam-search \
  --prompt "NixOS, fcitx5, kubectl" --remove-fillers

# Commands via stdin (manual mode):
echo "start" | stt-stream  # begin recording
echo "stop" | stt-stream   # stop and transcribe
echo "cancel" | stt-stream # cancel without transcribing
echo "shutdown" | stt-stream # exit
```

### Output Format (NDJSON)

```json
{"type":"ready"}
{"type":"recording_started"}
{"type":"partial","text":"hello worl"}
{"type":"partial","text":"hello world"}
{"type":"final","text":"Hello world."}
{"type":"recording_stopped"}
{"type":"shutdown"}
```

## Models

Models are automatically downloaded from Hugging Face on first run and cached in `~/.cache/stt-stream/models/`.

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| tiny.en | ~75MB | Fastest | Basic |
| base.en | ~150MB | Fast | Good (default) |
| small.en | ~500MB | Medium | Better |
| medium.en | ~1.5GB | Slow | Great |
| large-v3-turbo | ~1.6GB | Fast on GPU | Near-best (multilingual, **recommended for GPU**) |
| large-v3 | ~3GB | Slowest | Best (multilingual) |

When Silero VAD is enabled, a small VAD model (`ggml-silero-v5.1.2.bin`, a few MB)
is also downloaded to the same cache directory.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--mode` | `manual` | `manual`, `oneshot`, or `continuous` |
| `--model` / `-M` | `base.en` | Model name (see table above) |
| `--model-path` | — | Explicit path to a `.bin` model (overrides `--model`) |
| `--vad` | `simple` | `simple` (energy) or `silero` (whisper.cpp built-in) |
| `--vad-threshold` | `0.5` | Speech probability/energy threshold (0.0–1.0) |
| `--silence-ms` | `800` | Silence duration to end an utterance |
| `--min-speech-ms` | `250` | Min speech length for Silero to count as an utterance |
| `--speech-pad-ms` | `150` | Padding around speech (Silero) to avoid clipping edges |
| `--beam-search` | `false` | Use beam search on the final pass (slower, better) |
| `--prompt` | — | Initial prompt / custom vocabulary bias |
| `--remove-fillers` | `false` | Drop standalone `um`/`uh`/`erm` from finals |
| `--language` / `-l` | `en` | Language code (`en`, `ja`, `auto`, …) |
| `--gpu` | `false` | Request GPU acceleration |
| `--threads` | auto | Inference thread count |

## NixOS Module Options

`ringofstorms.sttIme.{ enable, model, gpuBackend, useGpu, vad, beamSearch,
vocabulary, removeFillers }`. The `vad` and `beamSearch` defaults derive from
`useGpu` (silero + beam search on GPU hosts).

## Environment Variables

CLI flags always take precedence over these; they are how the NixOS module
configures the binary launched by the fcitx5 addon.

- `STT_STREAM_MODEL_PATH`: Path to a specific model file
- `STT_STREAM_MODEL`: Model name
- `STT_STREAM_GPU`: Set to "1" for GPU acceleration
- `STT_STREAM_VAD`: `simple` or `silero`
- `STT_STREAM_VAD_THRESHOLD`: VAD threshold (0.0–1.0)
- `STT_STREAM_BEAM_SEARCH`: Set to "1" to enable beam search
- `STT_STREAM_PROMPT`: Custom vocabulary / initial prompt
- `STT_STREAM_REMOVE_FILLERS`: Set to "1" to remove filler words

## Building

```bash
cd flakes/stt_ime
nix build .#stt-stream    # Rust CLI only
nix build .#fcitx5-stt    # Fcitx5 addon (includes stt-stream)
nix build                  # Default: fcitx5-stt
```

## Integration with de_plasma

The addon is automatically added to Fcitx5 when `ringofstorms.sttIme.enable = true`.
It appears as "Speech to Text" (STT) in the input method switcher alongside US and Mozc.
