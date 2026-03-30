{ pkgs, lib, config, constants, ... }:
{
  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;

  # ── Bluetooth (Switch Pro Controllers) ─────────────────────────────────────
  hardware.bluetooth = {
    enable = true;
    # Power the adapter on at boot so controllers can reconnect automatically
    powerOnBoot = true;
    settings = {
      General = {
        # Reduce idle disconnect timeout (default 0 = use kernel default which
        # can be aggressive). 0 here means "never idle-disconnect".
        IdleTimeout = 0;
        # Allow the adapter to be discoverable immediately after boot so
        # controllers that were previously paired can reconnect faster.
        FastConnectable = true;
        # Experimental D-Bus interfaces improve battery reporting and
        # reconnection behavior for game controllers.
        Experimental = true;
      };
      Policy = {
        # Automatically re-connect to previously paired devices (controllers)
        AutoEnable = true;
      };
    };
  };

  # ── GPD Pocket 3 display ───────────────────────────────────────────────────
  # The GPD Pocket 3 uses a tablet display mounted rotated 90 degrees.
  boot.kernelParams = [
    "video=DSI-1:panel_orientation=right_side_up"
    "fbcon=rotate:1"
    "mem_sleep_default=s2idle"
  ];

  # ── HDMI ARC audio (TV → soundbar passthrough) ─────────────────────────────
  # The Intel HDA codec power-saves aggressively, suspending the HDMI audio
  # sink after a few seconds of silence. When ARC wakes it back up, the
  # re-negotiation produces audible static/pops. Disabling power_save keeps
  # the codec active so the ARC link stays clean.
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=0
  '';

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
  services.tlp = {
    enable = true;
    settings = {
      # Prevent TLP from re-enabling audio codec power save (which would
      # override our snd_hda_intel.power_save=0 and cause HDMI ARC static).
      SOUND_POWER_SAVE_ON_AC = 0;
      SOUND_POWER_SAVE_ON_BAT = 0;
      # Prevent TLP from autosuspending the Bluetooth adapter, which drops
      # controller connections. Exclude btusb from USB autosuspend.
      USB_AUTOSUSPEND = 1;
      USB_EXCLUDE_BTUSB = 1;
    };
  };

  # ── PipeWire: keep HDMI sink alive ─────────────────────────────────────────
  # By default PipeWire suspends idle audio nodes after a timeout.  When the
  # node resumes, the HDMI ARC link re-negotiates and produces static.
  # session.suspend-timeout-seconds = 0 disables this.
  services.pipewire.wireplumber.extraConfig."10-disable-suspend" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          { "node.name" = "~alsa_output.pci-.*hdmi.*"; }
        ];
        actions.update-props = {
          "session.suspend-timeout-seconds" = 0;
        };
      }
    ];
  };

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

  # ── Sunshine (remote desktop for Moonlight clients) ─────────────────────────
  # Streams the KDE Wayland desktop over the Tailnet.  Pair with Moonlight
  # on any client to remote-control this box.
  #
  # First-time setup:
  #   1. Open https://localhost:47990 on gp3 (or https://<gp3-tailscale-ip>:47990
  #      from any tailnet host) to reach the Sunshine web UI.
  #   2. Create a username / password when prompted.
  #   3. On the client, open Moonlight → Add Host → enter gp3's Tailscale IP.
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
