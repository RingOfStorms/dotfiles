{ pkgs, lib, constants, ... }:
{
  hardware.enableAllFirmware = true;

  # TODO: Switch to pkgs.linuxPackages_zen when nixpkgs-unstable syncs zen with NVIDIA
  # (zen stuck at 6.18.13, latest at 6.19.6, NVIDIA needs 6.18.16 as of 2026-03-12)
  # Using default linuxPackages (6.18.16) which matches the NVIDIA driver.
  # boot.kernelPackages = pkgs.linuxPackages_zen;

  # ── NVIDIA + uinput early module loading ──────────────────────────────────
  # Force-load all NVIDIA kernel modules at boot (matches Bazzite behavior).
  # nvidia-uvm is critical -- without it, DXVK/VKD3D-Proton can enumerate the
  # GPU adapter but fail at device creation (E_FAIL 0x80004005).
  # uinput is in initrd (not just boot.kernelModules) because systemd-modules-load
  # was failing to load it, and Steam needs /dev/uinput to exist before it starts
  # for Remote Play virtual gamepad/keyboard/mouse input forwarding.
  boot.initrd.kernelModules = [
    "nvidia"
    "nvidia_modeset"
    "nvidia_uvm"
    "nvidia_drm"
    "uinput"
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

  # ── Steam Remote Play input forwarding ─────────────────────────────────────
  # Steam creates virtual input devices via /dev/uinput to forward client
  # keyboard/mouse/gamepad input. The steam-devices uaccess tag doesn't
  # reliably propagate into Steam's FHS sandbox, so we grant group-level
  # access instead. User josh is already in the input group.
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input"
  '';

  # ── Steam ──────────────────────────────────────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;
    protontricks.enable = true;
    # Translate X11 XTEST calls to uinput events on Wayland -- needed for
    # Steam Remote Play keyboard/mouse input injection via XWayland
    extest.enable = true;
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

  # ── Sunshine (remote desktop for Moonlight clients) ─────────────────────────
  # Streams the KDE Wayland desktop over the Tailnet.  Pair with Moonlight
  # on any client to remote-control this box.
  #
  # First-time setup:
  #   1. Open https://localhost:47990 on joe (or https://<joe-tailscale-ip>:47990
  #      from any tailnet host) to reach the Sunshine web UI.
  #   2. Create a username / password when prompted.
  #   3. On the client, open Moonlight → Add Host → enter joe's Tailscale IP.
  #   4. A PIN will appear in Moonlight — enter it in the Sunshine web UI to pair.
  services.sunshine = {
    enable = true;
    autoStart = true;         # start with graphical session
    capSysAdmin = true;       # required for DRM/KMS capture on Wayland
    openFirewall = false;     # we only expose on the Tailscale interface below
    settings = {
      sunshine_name = constants.host.name;
    };
  };

  # Only allow Sunshine ports on the Tailscale interface
  networking.firewall.interfaces."tailscale0" = {
    allowedTCPPorts = [ 47984 47989 47990 48010 ];
    allowedUDPPorts = [ 47998 47999 48000 48002 48010 ];
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
