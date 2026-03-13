{ pkgs, lib, ... }:
{
  hardware.enableAllFirmware = true;

  # TODO: Switch to pkgs.linuxPackages_zen when nixpkgs-unstable syncs zen with NVIDIA
  # (zen stuck at 6.18.13, latest at 6.19.6, NVIDIA needs 6.18.16 as of 2026-03-12)
  # Using default linuxPackages (6.18.16) which matches the NVIDIA driver.
  # boot.kernelPackages = pkgs.linuxPackages_zen;

  # ── NVIDIA early module loading ─────────────────────────────────────────────
  # Force-load all NVIDIA kernel modules at boot (matches Bazzite behavior).
  # nvidia-uvm is critical -- without it, DXVK/VKD3D-Proton can enumerate the
  # GPU adapter but fail at device creation (E_FAIL 0x80004005).
  boot.initrd.kernelModules = [
    "nvidia"
    "nvidia_modeset"
    "nvidia_uvm"
    "nvidia_drm"
  ];

  # ── Graphics / VA-API ───────────────────────────────────────────────────────
  hardware.graphics.extraPackages = with pkgs; [
    nvidia-vaapi-driver # Hardware video decode (VA-API via NVDEC) for browsers/mpv
  ];

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # SSD trim
  services.fstrim.enable = true;

  # ── Steam ──────────────────────────────────────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;
    protontricks.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };

  # ── Gaming utilities ───────────────────────────────────────────────────────
  programs.gamemode = {
    enable = true;
    enableRenice = true;
    settings = {
      general = {
        renice = 10;
      };
      custom = {
        start = "${lib.getExe pkgs.libnotify} 'GameMode started'";
        end = "${lib.getExe pkgs.libnotify} 'GameMode ended'";
      };
    };
  };

  programs.gamescope = {
    enable = true;
    capSysNice = true; # Allow gamescope to set real-time scheduling
  };

  environment.systemPackages = with pkgs; [
    mangohud     # Performance overlay (MANGOHUD=1 %command% or mangohud %command%)
    protonup-qt  # GUI for managing custom Proton versions
    vulkan-tools # vulkaninfo for diagnostics
  ];

  # ── Gaming environment variables (Bazzite parity) ──────────────────────────
  environment.sessionVariables = {
    # VKD3D-Proton: prevent swapchain starvation in DX12 games
    VKD3D_SWAPCHAIN_LATENCY_FRAMES = "3";
    # Gamescope WSI Vulkan layer
    ENABLE_GAMESCOPE_WSI = "1";
    # NVIDIA crash fix (from Bazzite's nvidia steam wrapper)
    __GL_CONSTANT_FRAME_RATE_HINT = "3";
    # Mesa multi-threading
    mesa_glthread = "true";
    # Don't minimize fullscreen games on focus loss
    SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS = "0";
    # Xwayland: don't wait for idle buffers before sending to gamescope
    vk_xwayland_wait_ready = "false";
    # nvidia-vaapi-driver: use direct backend for hardware video decode
    NVD_BACKEND = "direct";
  };
}
