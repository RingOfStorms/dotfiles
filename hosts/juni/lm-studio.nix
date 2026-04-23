{
  pkgs,
  lib,
  ...
}:
# LM Studio: proprietary local-LLM desktop app (chat GUI + model browser +
# optional OpenAI-compatible local server). Distributed only as an AppImage
# from lmstudio.ai — not in nixpkgs, not on Flathub.
#
# This wraps the upstream AppImage with appimageTools.wrapType2 so it's
# installed declaratively and shows up in the Plasma application menu. State
# (downloaded models, chats, settings) lives under ~/.lmstudio — persisted
# via impermanence.nix.
#
# To bump:
#   1. Find the latest version at https://lmstudio.ai/changelog
#   2. Update `version` and `build` below
#   3. Run `nix-prefetch-url <url>` and update `hash`
let
  version = "0.4.12";
  build = "1";

  src = pkgs.fetchurl {
    url = "https://installers.lmstudio.ai/linux/x64/${version}-${build}/LM-Studio-${version}-${build}-x64.AppImage";
    hash = "sha256:1hnb0qx154f6s9hgbdmbnv7hb0pzfs1p1wxyjcbbx61aqn8ckd2k";
  };

  # Extract the AppImage so we can grab the .desktop and icon for the
  # Plasma menu, and pin a stable wrapper name (`lm-studio`) regardless of
  # the AppImage's internal naming.
  appimageContents = pkgs.appimageTools.extract {
    pname = "lm-studio";
    inherit version src;
  };

  lm-studio = pkgs.appimageTools.wrapType2 {
    pname = "lm-studio";
    inherit version src;

    # Electron-based app — needs the standard FHS runtime libs that
    # appimageTools provides plus the usual GUI extras.
    extraPkgs =
      pkgs:
      (with pkgs; [
        # Hardware video decode (Intel iGPU)
        libva
        # Vulkan for llama.cpp on Intel iGPU (LM Studio's bundled runtime
        # picks this up if present)
        vulkan-loader
        mesa
        # Misc Electron deps that AppImages frequently need at runtime
        libsecret
        libnotify
      ]);

    extraInstallCommands = ''
      install -Dm644 ${appimageContents}/lm-studio.desktop $out/share/applications/lm-studio.desktop
      install -Dm644 ${appimageContents}/lm-studio.png $out/share/icons/hicolor/512x512/apps/lm-studio.png
      substituteInPlace $out/share/applications/lm-studio.desktop \
        --replace-quiet 'Exec=AppRun' 'Exec=lm-studio'
    '';

    meta = {
      description = "Discover, download, and run local LLMs (proprietary GUI app)";
      homepage = "https://lmstudio.ai/";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "lm-studio";
    };
  };
in
{
  nixpkgs.config.allowUnfreePredicate =
    pkg: builtins.elem (lib.getName pkg) [ "lm-studio" ];

  environment.systemPackages = [ lm-studio ];
}
