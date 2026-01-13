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
    model = "base.en";  # tiny, base, small, medium, large-v3 (add .en for English-only)
    useGpu = false;     # set true for CUDA acceleration
  };
}
```

### Standalone CLI

```bash
# Run with default settings (manual mode)
stt-stream

# Run in continuous mode
stt-stream --mode continuous

# Use a specific model
stt-stream --model small-en

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
| large-v3 | ~3GB | Slowest | Best (multilingual) |

## Environment Variables

- `STT_STREAM_MODEL_PATH`: Path to a specific model file
- `STT_STREAM_MODEL`: Model name (overridden by CLI)
- `STT_STREAM_USE_GPU`: Set to "1" for GPU acceleration

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
