{
  osConfig,
  lib,
  ...
}:
let
  cfg = osConfig.ringofstorms.dePlasma;
  inherit (lib) mkIf;
in
{
  imports = [
    ./shortcuts.nix
  ];
  options = { };
  config = mkIf cfg.enable {
    programs.feh.enable = true; # Image preview
    programs.plasma = {
      enable = true;
      immutableByDefault = true;
      overrideConfig = true;

      desktop = {
        mouseActions = {
          leftClick = null;
          middleClick = "contextMenu";
          rightClick = "contextMenu";
        };

        widgets = [
          # {
          #   plasmusicToolbar = {
          #     background = "transparentShadow";
          #     position = {
          #       horizontal = 51;
          #       vertical = 300;
          #     };
          #     size = {
          #       height = 400;
          #       width = 250;
          #     };
          #   };
          # }
        ];
      };

      fonts = {
        fixedWidth = {
          family = "JetBrainsMono Nerd Font Mono";
          pointSize = 11;
        };
        # general = {
        #   family = "";
        #   pointSize = 11;
        # };
      };

      input = {
        keyboard = {
          layouts = [
            { layout = "us"; }
          ];
          options = [ "caps:escape" ];
        };
        mice = [
          # {
          #   acceleration = 0.5;
          #   accelerationProfile = "none";
          #   enable = true;
          #   leftHanded = false;
          #   middleButtonEmulation = false;
          #   name = "Logitech G403 HERO Gaming Mouse";
          #   naturalScroll = false;
          #   productId = "c08f";
          #   scrollSpeed = 1;
          #   vendorId = "046d";
          # }
        ];
        touchpads = [
          # {
          #   disableWhileTyping = true;
          #   enable = true;
          #   leftHanded = true;
          #   middleButtonEmulation = true;
          #   name = "PNP0C50:00 0911:5288 Touchpad";
          #   naturalScroll = true;
          #   pointerSpeed = 0;
          #   productId = "21128";
          #   tapToClick = true;
          #   vendorId = "2321";
          # }
        ];
      };

      krunner = {
        activateWhenTypingOnDesktop = true;
        historyBehavior = "enableAutoComplete";
        position = "center";
        shortcuts = {
          launch = "Meta+Space";
          runCommandOnClipboard = "Meta+Shift+Space";
        };
      };

      kscreenlocker = {
        appearance = {
          alwaysShowClock = true;
          showMediaControls = true;
          wallpaper = ../../../hosts/_shared_assets/wallpapers/pixel_night.png;
          # wallpaperPlainColor = "0,64,174,256";
        };
        autoLock = false;
        lockOnResume = true;
        lockOnStartup = false;
        passwordRequired = true;
        timeout = 5;
      };

      kwin = {
        borderlessMaximizedWindows = true;
        cornerBarrier = false;
        edgeBarrier = 50;
        effects = {
          blur.enable = false;
          desktopSwitching = {
            animation = "off";
            navigationWrapping = true;
          };
          dimInactive.enable = false;
          fallApart.enable = false;
          hideCursor = {
            enable = true;
            hideOnInactivity = 10;
            hideOnTyping = true;
          };
          shakeCursor.enable = false;
          snapHelper.enable = true;
          translucency.enable = false;
          windowOpenClose.animation = "off";
          wobblyWindows.enable = false;
        };
        nightLight.enable = false;
        scripts = {
          polonium.enable = false;
        };
        # TODO these are not showing in pager for some reason? Set right?
        virtualDesktops = {
          names = [
            "一"
            "二"
            "三"
            "四"
            "五"
            "六"
            "七"
            "八"
            "九"
          ];
          rows = 1;
        };
      };

      panels = [
        {
          location = "top";
          alignment = "left";
          lengthMode = "fit";
          height = 24;
          opacity = "translucent"; # "adaptive" | "translucent" | "opaque"
          floating = true;
          hiding = "normalpanel";
          screen = "all";
          widgets = [
            {
              name = "org.dhruv8sh.kara";
              config = {
                general = {
                  spacing = 3;
                  type = 1;
                };
                type2 = {
                  fixedLen = 25;
                  labelSource = 1;
                };
              };
            }
          ];
        }
        {
          location = "top";
          alignment = "center";
          lengthMode = "fit";
          height = 24;
          opacity = "translucent"; # "adaptive" | "translucent" | "opaque"
          floating = true;
          hiding = "normalpanel";
          screen = "all";
          widgets = [
            "org.kde.plasma.digitalclock"
          ];
        }
        {
          location = "top";
          alignment = "right";
          lengthMode = "fit";
          height = 24;
          opacity = "translucent"; # "adaptive" | "translucent" | "opaque"
          floating = true;
          hiding = "normalpanel";
          screen = "all";
          widgets = [
            "org.kde.plasma.systemtray"
          ];
        }
        {
          location = "bottom";
          alignment = "center";
          lengthMode = "fit";
          height = 30;
          opacity = "translucent"; # "adaptive" | "translucent" | "opaque"
          floating = true;
          hiding = "dodgewindows";
          widgets = [
            "org.kde.plasma.kickoff"
            "org.kde.plasma.icontasks"
          ];
        }
      ];

      powerdevil = {
        AC = {
          autoSuspend.action = "nothing";
          dimDisplay.enable = false;
          dimKeyboard.enable = false;
          inhibitLidActionWhenExternalMonitorConnected = true;
          powerButtonAction = "turnOffScreen";
          powerProfile = "performance";
          whenLaptopLidClosed = "turnOffScreen";
        };
        battery = {
          autoSuspend.action = "nothing";
          dimDisplay.enable = false;
          dimKeyboard.enable = false;
          inhibitLidActionWhenExternalMonitorConnected = true;
          powerButtonAction = "turnOffScreen";
          powerProfile = "balanced";
          whenLaptopLidClosed = "sleep";
        };
        batteryLevels = {
          criticalAction = "shutDown";
          criticalLevel = 3;
          lowLevel = 15;
        };
        lowBattery.autoSuspend.action = "nothing";
        general = {
          pausePlayersOnSuspend = true;
        };
      };

      session = {
        general.askForConfirmationOnLogout = false;
        sessionRestore = {
          excludeApplications = [ ];
          restoreOpenApplicationsOnLogin = "onLastLogout";
        };
      };

      # Window rules for specific applications
      window-rules = [
        {
          description = "Kitty - No window decorations";
          match = {
            window-class = {
              value = "kitty";
              type = "exact";
            };
          };
          apply = {
            noborder = {
              value = true;
              apply = "force"; # Force this setting
            };
          };
        }
      ];

      windows = {
        allowWindowsToRememberPositions = true;
      };

      workspace = {
        enableMiddleClickPaste = true;
        clickItemTo = "open";
        colorScheme = "BreezeDark";
        lookAndFeel = "org.kde.breezedark.desktop";
        theme = "breeze-dark";
        cursor.theme = "breeze_cursors";
        wallpaper = [
          ../../../hosts/_shared_assets/wallpapers/pixel_neon.png
          ../../../hosts/_shared_assets/wallpapers/pixel_neon_v.png
        ];
      };

      configFile = {
        kwalletrc.Wallet.Enabled = false;
        plasmanotifyrc.Notifications.PopupPosition = "TopRight";
      };
    };
  };
}
