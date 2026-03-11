{ pkgs, lib, config, ... }:
{
  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # ── GPD Pocket 3 display ───────────────────────────────────────────────────
  # The GPD Pocket 3 uses a tablet display mounted rotated 90 degrees.
  boot.kernelParams = [
    "video=DSI-1:panel_orientation=right_side_up"
    "fbcon=rotate:1"
    "mem_sleep_default=s2idle"
  ];

  # Large console font for the small panel
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-132n.psf.gz";

  # Accelerometer for screen rotation
  hardware.sensor.iio.enable = true;

  # Brightness control
  # Brightness control (light was removed from nixpkgs)
  hardware.acpilight.enable = true;

  # SSD trim
  services.fstrim.enable = true;
  services.libinput.enable = true;

  # ── Battery ────────────────────────────────────────────────────────────────
  # NOTE: The GPD Pocket 3 does NOT support software-controlled battery charge
  # thresholds on Linux. The embedded controller firmware does not expose
  # charge_control_start_threshold / charge_control_end_threshold via sysfs,
  # and GPD is not among TLP's supported battery care vendors.
  #
  # Options if always plugged in:
  #   1. Check BIOS for any charge limit setting (unlikely)
  #   2. Use a smart plug with power monitoring to cut/restore power at thresholds
  #   3. Accept limitation -- modern Li-ion charge controllers prevent overcharge
  #
  # TLP is still useful for CPU power management even without battery thresholds.
  services.power-profiles-daemon.enable = false;
  services.tlp.enable = true;

  # ── Steam (Remote Play client + local games) ───────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # UDP/TCP ports for streaming from joe
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
  };

  # ── Gaming / Media utilities ───────────────────────────────────────────────
  programs.gamemode.enable = true;

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  environment.systemPackages = with pkgs; [
    git
    mangohud
    brightnessctl
    acpi # Battery status
  ];

  environment.shellAliases = {
    battery = "acpi";
    wifi = "nmtui";
  };
}
