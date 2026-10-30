# joe

Desktop (HP OMEN 20L)

## Hardware

| Component | Spec |
|---|---|
| Model | HP OMEN 20L Desktop |
| CPU | Intel Core i7-10700K (8C/16T, up to 5.1 GHz) |
| GPU | NVIDIA GeForce RTX 3080 |
| RAM | 32 GB |
| Storage | Not yet inventoried |
| Displays | Samsung C34J79x 34" 3440x1440 100 Hz; ASUS PG43U 43" 4K 60 Hz |

## Bare-metal services

| Service | Notes |
|---|---|
| Per-host agents | sec-agent, fail2ban, tailscaled |

Floating: `localai` (podman, `cnt ls`). Its generated media is swept nightly by
the `localai-cleanup` timer (`localai-cleanup.nix`, 24 h retention).

## GPU tensor unlock

`gpu-unlock.nix` runs [gpu-unlock](https://github.com/Zagitta/gpu-unlock) in
the initrd before `nvidia` binds, lifting GeForce's half-rate FP16/BF16/TF32
tensor math with FP32 accumulation. Helps FP16/BF16 diffusion and prompt
processing; quantized decode and games are unchanged. Takes effect on reboot.

```sh
ssh root@joe journalctl -k -b | grep gpu_unlock
```

If boot hangs or the screen stays dark: power the machine fully off (a hung
unlock keeps its DMA buffers until power-off; a warm reboot is not enough),
then remove `gpu_unlock.targets=…` in the systemd-boot editor (`e`) or pick an
older generation.
