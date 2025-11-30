{
  config,
  lib,
  pkgs,
  plasma-manager,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    mkEnableOption
    mkIf
    mkMerge
    optionals
    length
    filter
    ;
  cfg = config.ringofstorms.dePlasma;
  oneGpuEnabled =
    (length (
      filter (x: x) [
        cfg.gpu.nvidia.enable or false
        cfg.gpu.amd.enable or false
        cfg.gpu.intel.enable or false
      ]
    )) <= 1;
  panelDefaults = {
    enabled = true;
    location = "top";
    height = 28;
    opacity = "translucent"; # "adaptive" | "translucent" | "opaque"
    widgets = [
      "org.kde.plasma.kickoff"
      "org.kde.plasma.icontasks"
      "org.kde.plasma.systemtray"
      "org.kde.plasma.networkmanagement"
      "org.kde.plasma.bluetooth"
      "org.kde.plasma.volume"
      "org.kde.plasma.battery"
      "org.kde.plasma.powerprofiles"
      "org.kde.plasma.notifications"
      "org.kde.plasma.digitalclock"
    ];
  };
in
{
  options.ringofstorms.dePlasma = {
    enable = mkEnableOption "KDE Plasma desktop";

    wayland = mkOption {
      type = types.bool;
      default = true;
      description = "Enable SDDM Wayland and Plasma Wayland session.";
    };

    appearance.dark.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Breeze Dark, GTK Breeze-Dark, and dark cursors.";
    };

    flatpak.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Flatpak.";
    };

    sddm.autologinUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Set an autologin user for SDDM (optional).";
    };

    gpu = {
      enable32Bit = mkOption {
        type = types.bool;
        default = true;
        description = "Install 32-bit OpenGL/VA-API bits (useful for Steam/Wine).";
      };
      nvidia = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        open = mkOption {
          type = types.bool;
          default = true;
        };
        package = mkOption {
          type = types.package;
          default = pkgs.linuxPackages.nvidiaPackages.production;
        };
      };
      amd = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        useAmdvlk = mkOption {
          type = types.bool;
          default = false;
        };
      };
      intel = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
        legacyVaapi = mkOption {
          type = types.bool;
          default = false;
        };
      };
    };

    panel = {
      enabled = mkOption {
        type = types.bool;
        default = panelDefaults.enabled;
      };
      location = mkOption {
        type = types.enum [
          "top"
          "bottom"
          "left"
          "right"
        ];
        default = panelDefaults.location;
      };
      height = mkOption {
        type = types.int;
        default = panelDefaults.height;
      };
      opacity = mkOption {
        type = types.enum [
          "adaptive"
          "translucent"
          "opaque"
        ];
        default = panelDefaults.opacity;
      };
      widgets = mkOption {
        type = types.listOf types.str;
        default = panelDefaults.widgets;
      };
    };

    shortcuts = {
      terminal = mkOption {
        type = types.str;
        default = "kitty";
      };
      launcher = mkOption {
        type = types.enum [
          "krunner"
          "rofi"
        ];
        default = "krunner";
      };
      useI3Like = mkOption {
        type = types.bool;
        default = true;
      };
      closeWindow = mkOption {
        type = types.str;
        default = "Meta+Q";
      };
      workspaceKeys = mkOption {
        type = types.listOf types.str;
        default = [
          "Meta+1"
          "Meta+2"
          "Meta+3"
          "Meta+4"
          "Meta+5"
          "Meta+6"
          "Meta+7"
          "Meta+8"
          "Meta+9"
        ];
      };
      moveWindowWorkspaceKeys = mkOption {
        type = types.listOf types.str;
        default = [
          "Meta+Shift+1"
          "Meta+Shift+2"
          "Meta+Shift+3"
          "Meta+Shift+4"
          "Meta+Shift+5"
          "Meta+Shift+6"
          "Meta+Shift+7"
          "Meta+Shift+8"
          "Meta+Shift+9"
        ];
      };
    };

    monitors = {
      enableOverrides = mkOption {
        type = types.bool;
        default = false;
      };
      commands = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      scriptDelayMs = mkOption {
        type = types.int;
        default = 500;
      };
    };

    apps.include = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [
        kdePackages.kde-gtk-config
        kdePackages.konsole
        kdePackages.dolphin
        kdePackages.spectacle
        kdePackages.plasma-browser-integration
        kdePackages.plasma-workspace-wallpapers
      ];
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
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

      # Portals
      xdg.portal.enable = true;
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

      # Audio / IPC
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };

      services.power-profiles-daemon.enable = true;
      services.flatpak.enable = cfg.flatpak.enable;

      # Wayland-friendly Electron/Chromium
      environment.sessionVariables.NIXOS_OZONE_WL = "1";

      # OpenGL base
      hardware.opengl = {
        enable = true;
        driSupport32Bit = cfg.gpu.enable32Bit;
      };

      # KDEConnect
      programs.kdeconnect.enable = true;

      # Useful KDE packages
      environment.systemPackages = cfg.apps.include;

      # Keyboard like sway/i3
      console.useXkbConfig = true;
      services.xserver.xkb = {
        layout = "us";
        options = "caps:escape";
      };

      # Home Manager modules (plasma-manager + our HM layer)
      home-manager.sharedModules = [
        plasma-manager.homeManagerModules.plasma-manager
        ./home_manager
      ];
    }

    # Make GTK apps dark too if enabled
    (mkIf cfg.appearance.dark.enable {
      environment.sessionVariables = {
        GTK_THEME = "Breeze-Dark";
        XCURSOR_THEME = "breeze_cursors";
      };
    })

    (mkIf cfg.appearance.dark.enable {
      environment.systemPackages = with pkgs; [
        kdePackages.breeze
        kdePackages.breeze-icons
        kdePackages.breeze-gtk
      ];
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
    })

    # GPU blocks
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
      environment.systemPackages = optionals cfg.gpu.amd.useAmdvlk [ pkgs.amdvlk ];
    })

    (mkIf cfg.gpu.intel.enable {
      services.xserver.videoDrivers = [ "modesetting" ];
      hardware.opengl.extraPackages =
        with pkgs;
        [
          intel-media-driver
          libvdpau-va-gl
        ]
        ++ optionals cfg.gpu.intel.legacyVaapi [ pkgs.vaapiIntel ];
      hardware.opengl.extraPackages32 =
        with pkgs.pkgsi686Linux;
        [
          libva
          libvdpau-va-gl
        ]
        ++ optionals cfg.gpu.intel.legacyVaapi [ pkgs.vaapiIntel ];
    })

    (mkIf cfg.gpu.nvidia.enable {
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.nvidia = {
        package = cfg.gpu.nvidia.package;
        modesetting.enable = true;
        powerManagement.enable = true;
        open = cfg.gpu.nvidia.open;
        nvidiaSettings = true;
      };
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
          message = "Enable at most one of ringofstorms.dePlasma.gpu.{nvidia,amd,intel}.enable.";
        }
      ];
    }
  ]);
}
