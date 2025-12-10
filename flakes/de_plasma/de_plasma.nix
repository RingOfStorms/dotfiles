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
in
{
  options.ringofstorms.dePlasma = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable KDE Plasma DE.";
    };

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
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.displayManager.sddm = {
        enable = true;
        wayland.enable = cfg.wayland;
        theme = "breeze";
      };
      services.displayManager.autoLogin = mkIf (cfg.sddm.autologinUser != null) {
        enable = true;
        user = cfg.sddm.autologinUser;
      };
      services.desktopManager.plasma6.enable = true;


      # Audio / IPC
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };

      # TODO revisit
      # services.power-profiles-daemon.enable = true;

      # Wayland-friendly Electron/Chromium
      environment.sessionVariables.NIXOS_OZONE_WL = "1";

      # OpenGL base
      hardware.graphics = {
        enable = true;
        enable32Bit = cfg.gpu.enable32Bit;
      };

      # KDEConnect
      programs.kdeconnect.enable = true;

       # Useful KDE packages
       environment.systemPackages = with pkgs; [
         # Core KDE tools
         kdePackages.kde-gtk-config
         kdePackages.konsole
         kdePackages.dolphin
         kdePackages.spectacle
         kdePackages.plasma-browser-integration
         # kdePackages.plasma-workspace-wallpapers
 
         # Panel applets required for widgets
         kdePackages.plasma-nm # org.kde.plasma.networkmanagement
         kdePackages.bluedevil # org.kde.plasma.bluetooth
         kdePackages.plasma-pa # org.kde.plasma.volume
         kdePackages.kdeplasma-addons # extra widgets
         kdePackages.powerdevil # power management services
 
         # Wayland clipboard helpers
         wl-clipboard
         wl-clip-persist
       ];


      # Keyboard like sway/i3
      console.useXkbConfig = true;
      services.xserver.xkb = {
        layout = "us";
        options = "caps:escape";
      };

      # Home Manager modules (plasma-manager + our HM layer)
      home-manager.sharedModules = [
        plasma-manager.homeModules.plasma-manager
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
      hardware.graphics.extraPackages = with pkgs; [
        libva-vdpau-driver
        libvdpau-va-gl
      ];
      hardware.graphics.extraPackages32 = with pkgs.pkgsi686Linux; [
        libva
        libva-vdpau-driver
        libvdpau-va-gl
      ];
      environment.systemPackages = optionals cfg.gpu.amd.useAmdvlk [ pkgs.amdvlk ];
    })

    (mkIf cfg.gpu.intel.enable {
      services.xserver.videoDrivers = [ "modesetting" ];
      hardware.graphics.extraPackages =
        with pkgs;
        [
          intel-media-driver
          libvdpau-va-gl
        ]
        ++ optionals cfg.gpu.intel.legacyVaapi [ pkgs.vaapiIntel ];
      hardware.graphics.extraPackages32 =
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
