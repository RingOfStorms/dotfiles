{ pkgs, ... }:
{
  hardware.enableAllFirmware = true;

  # TODO: Switch to pkgs.linuxPackages_zen when nixpkgs-unstable syncs zen with NVIDIA
  # (zen stuck at 6.18.13, NVIDIA needs 6.18.16 as of 2026-03-12)
  boot.kernelPackages = pkgs.linuxPackages_latest;

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
