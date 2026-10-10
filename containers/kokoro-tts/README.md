# kokoro-tts (joe)

Same image, port (8880) and data as the old `hosts/joe/kokoro-tts.nix`.

Data to keep from `joe:/var/lib/kokoro-tts`:
- `models/v1_0/` (313 MB, `kokoro-v1_0.pth` + config). Re-downloadable
  (`DOWNLOAD_MODEL=true`) but cheap to copy.
- `voices/` is empty (no custom voice packs).

Switch-over on joe (after the host rebuild with `containers.nix`):

```sh
sudo systemctl stop podman-kokoro-tts
sudo install -d /srv/containers/kokoro-tts
sudo cp -a /var/lib/kokoro-tts/models /var/lib/kokoro-tts/voices /srv/containers/kokoro-tts/
cnt deploy kokoro-tts
curl -s http://joe:8880/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","input":"hello","voice":"af_heart"}' -o /tmp/t.mp3
```

Owner 1001 (appuser) is kept by `cp -a`; the idmapped mount shows it
as-is inside the container. Then remove `hosts/joe/kokoro-tts.nix` and its
persistence entry and rebuild.
