{ pkgs, ... }:
{
  system.stateVersion = "25.11";

  hardware.enableAllFirmware = true;

  # Use Zen kernel for lower latency desktop/gaming performance
  boot.kernelPackages = pkgs.linuxPackages_zen;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # ── Steam ──────────────────────────────────────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    gamescopeSession.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };

  # ── Gaming utilities ───────────────────────────────────────────────────────
  programs.gamemode.enable = true;

  programs.gamescope = {
    enable = true;
    capSysNice = true; # Allow gamescope to set real-time scheduling
  };

  environment.systemPackages = with pkgs; [
    mangohud   # Performance overlay (use MANGOHUD=1 or mangohud %command%)
    protonup-qt # GUI for managing custom Proton versions
  ];
}
