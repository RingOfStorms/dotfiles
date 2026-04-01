{
  pkgs,
  lib,
  config,
  ...
}:
{
  hardware.enableAllFirmware = true;
  hardware.bluetooth.enable = true;
  networking.networkmanager.enable = true;
  environment.shellAliases = {
    wifi = "nmtui";
    battery = "acpi";
  };
  boot.kernelModules = [
    "rtl8192ce"
    "rtl8192c_common"
    "rtlwifi"
    "mac80211"
  ];
  # Allow emulation of aarch64-linux binaries for cross compiling
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # ── Virtual input device access (uinput) ───────────────────────────────────
  # Steam creates virtual input devices via /dev/uinput to forward client
  # keyboard/mouse/gamepad input. Grant group-level access so the logged-in
  # user can create virtual devices without root.
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

  environment.systemPackages = with pkgs; [

    # [Laptop] Battery status
    acpi
    bluez # bluetoothctl command

    mangohud     # Performance overlay (MANGOHUD=1 %command% or mangohud %command%)
    protonup-qt  # GUI for managing custom Proton versions
    vulkan-tools # vulkaninfo for diagnostics
    steam-run
  ];

  # ── Gaming environment variables ───────────────────────────────────────────
  environment.sessionVariables = {
    # VKD3D-Proton: prevent swapchain starvation in DX12 games
    VKD3D_SWAPCHAIN_LATENCY_FRAMES = "3";
    # Gamescope WSI Vulkan layer
    ENABLE_GAMESCOPE_WSI = "1";
    # Mesa multi-threading
    mesa_glthread = "true";
    # Don't minimize fullscreen games on focus loss
    SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS = "0";
    # Xwayland: don't wait for idle buffers before sending to gamescope
    vk_xwayland_wait_ready = "false";
  };
}
