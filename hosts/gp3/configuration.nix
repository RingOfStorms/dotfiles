{ pkgs, ... }:
{
  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

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

  # Brightness control (light was removed from nixpkgs)
  hardware.acpilight.enable = true;

  # SSD trim
  services.fstrim.enable = true;
  services.libinput.enable = true;

  # ── Battery ────────────────────────────────────────────────────────────────
  # NOTE: The GPD Pocket 3 does NOT support software-controlled battery charge
  # thresholds on Linux (the EC does not expose charge_control_*_threshold).
  # TLP is still used for CPU/USB power management.
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      # Keep the Bluetooth adapter from being autosuspended (drops devices).
      USB_AUTOSUSPEND = 1;
      USB_EXCLUDE_BTUSB = 1;
    };
  };

  environment.systemPackages = with pkgs; [
    brightnessctl
    acpi # Battery status
  ];

  environment.shellAliases = {
    battery = "acpi";
    wifi = "nmtui";
  };
}
