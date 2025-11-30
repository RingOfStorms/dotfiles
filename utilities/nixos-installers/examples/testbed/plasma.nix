{ lib, pkgs, config, ... }:

let
  inherit (lib) mkOption types mkEnableOption mkIf mkMerge;
  cfg = config.myPlasma;

  oneGpuEnabled =
    (lib.length (lib.filter (x: x) [
      cfg.gpu.nvidia.enable
      cfg.gpu.amd.enable
      cfg.gpu.intel.enable
    ])) <= 1;
in
{
  options.myPlasma = {
    enable = mkEnableOption "KDE Plasma desktop";

    appearance.breezeDark = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Apply Breeze Dark system-wide (defaults via /etc/xdg and GTK_THEME).";
      };
    };

    wayland = mkOption {
      type = types.bool;
      default = true;
      description = "Enable SDDM Wayland and Plasma Wayland session.";
    };

    flatpak.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Flatpak.";
    };

    gpu = {
      enable32Bit = mkOption {
        type = types.bool;
        default = true;
        description = "Install 32-bit OpenGL/VA-API bits (useful for Steam/Wine).";
      };

      nvidia = {
        enable = mkOption { type = types.bool; default = false; };
        open = mkOption {
          type = types.bool;
          default = true;
          description = "Use NVIDIA open kernel module when available.";
        };
        package = mkOption {
          type = types.package;
          default = pkgs.linuxPackages.nvidiaPackages.production;
          description = "NVIDIA driver package.";
        };
      };

      amd = {
        enable = mkOption { type = types.bool; default = false; };
        useAmdvlk = mkOption {
          type = types.bool; default = false;
          description = "Install AMDVLK alongside Mesa (RADV stays default).";
        };
      };

      intel = {
        enable = mkOption { type = types.bool; default = false; };
        legacyVaapi = mkOption {
          type = types.bool; default = false;
          description = "Also add intel-vaapi-driver for very old Intel iGPUs.";
        };
      };
    };

    sddm.autologinUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Set an autologin user for SDDM (optional).";
    };

    powerManagement = mkOption {
      type = types.bool;
      default = true;
      description = "Enable ";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Core desktop
      services.displayManager.sddm = {
        enable = true;
        wayland.enable = cfg.wayland;
        theme = "breeze";
        autoLogin = mkIf (cfg.sddm.autologinUser != null) {
          enable = true;
          user = cfg.sddm.autologinUser;
        };
      };

      services.desktopManager.plasma6.enable = true;

      # Portals for sandboxed apps (Wayland, Flatpak)
      xdg.portal.enable = true;
      # KDE portal is pulled with Plasma; add GTK for broader app support
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

      # PipeWire + WirePlumber for audio
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };

      # Good defaults for laptops/desktops
      services.power-profiles-daemon.enable = lib.mkIf cfg.powerManagement true;

      # Flatpak
      services.flatpak.enable = cfg.flatpak.enable;

      # Wayland-friendly Electron/Chromium (prefer Wayland Ozone)
      environment.sessionVariables.NIXOS_OZONE_WL = "1";

      # OpenGL/VA-API/Vulkan base
      hardware.opengl = {
        enable = true;
        # driSupport = true;
        driSupport32Bit = cfg.gpu.enable32Bit;
      };

      # KDEConnect
      programs.kdeconnect.enable = true;

      # Useful KDE tools (minimal)
      environment.systemPackages = with pkgs; [
        kdePackages.kde-gtk-config
        kdePackages.konsole
        kdePackages.dolphin
        kdePackages.spectacle
        kdePackages.plasma-browser-integration
        kdePackages.plasma-workspace-wallpapers
      ];
    }

    (mkIf cfg.appearance.breezeDark.enable {
      # Ensure themes are present
      environment.systemPackages = with pkgs; [
        kdePackages.breeze
        kdePackages.breeze-icons
        kdePackages.breeze-gtk
      ];

      # KDE defaults for ALL users (users can still override in ~/.config)
      environment.etc."xdg/kdeglobals".text = ''
        [General]
        ColorScheme=BreezeDark

        [KDE]
        LookAndFeelPackage=org.kde.breezedark.desktop
        widgetStyle=Breeze

        [Icons]
        Theme=breeze-dark

        [Theme]
        cursorTheme=breeze_cursors
      '';

      # Make GTK apps dark too
      environment.sessionVariables.GTK_THEME = "Breeze-Dark";
      # Nice to have for cursors across toolkits
      environment.sessionVariables.XCURSOR_THEME = "breeze_cursors";
    })

    # AMD GPU
    (mkIf cfg.gpu.amd.enable {
      services.xserver.videoDrivers = [ "amdgpu" ];
      hardware.opengl.extraPackages = with pkgs; [
        vaapiVdpau
        libvdpau-va-gl
      ];
      hardware.opengl.extraPackages32 = with pkgs.pkgsi686Linux; [
        libva
        vaapiVdpau
        libvdpau-va-gl
      ];
      environment.systemPackages = lib.optionals cfg.gpu.amd.useAmdvlk [ pkgs.amdvlk ];
    })

    # Intel GPU
    (mkIf cfg.gpu.intel.enable {
      services.xserver.videoDrivers = [ "modesetting" ];
      hardware.opengl.extraPackages =
        with pkgs; [
          intel-media-driver
          libvdpau-va-gl
        ] ++ lib.optionals cfg.gpu.intel.legacyVaapi [ vaapiIntel ];
      hardware.opengl.extraPackages32 = with pkgs.pkgsi686Linux; [
        libva
        libvdpau-va-gl
      ] ++ lib.optionals cfg.gpu.intel.legacyVaapi [ vaapiIntel ];
    })

    # NVIDIA GPU
    (mkIf cfg.gpu.nvidia.enable {
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.nvidia = {
        package = cfg.gpu.nvidia.package;
        modesetting.enable = true;
        powerManagement.enable = true;
        open = cfg.gpu.nvidia.open;
        nvidiaSettings = true;
      };
      # Wayland helpers for wlroots/GBM stacks (harmless otherwise)
      environment.sessionVariables = {
        GBM_BACKEND = "nvidia-drm";
        __GL_GSYNC_ALLOWED = "0";
        __GL_VRR_ALLOWED = "0";
      };
    })

    {
      assertions = [
        {
          assertion = oneGpuEnabled;
          message = "Enable at most one of myPlasma.gpu.{nvidia,amd,intel}.enable.";
        }
      ];
    }
  ]);
}
