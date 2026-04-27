{ config, lib, pkgs, ... }:

let
  cfg = config.ringofstorms.plymouth;

  # Extract frames from infinite.gif, downsample temporally, optionally
  # downscale spatially, and quantize PNGs. The result is a directory
  # of frame-XXXX.png files copied into the theme at install time.
  #
  # The source GIF has 541 frames at ~33 fps (16.2 s). Default stride
  # of 12 yields ~45 frames, which loops cleanly at the 30 fps the
  # script assumes (~1.5 s loop). Tune via `frameStride`.
  infiniteFrames = pkgs.runCommand "infinite-frames"
    {
      nativeBuildInputs = [ pkgs.imagemagick pkgs.pngquant ];
      passAsFile = [ "stride" "maxWidth" ];
      stride = toString cfg.frameStride;
      maxWidth = toString cfg.maxWidth;
    } ''
      set -euo pipefail
      mkdir -p $out
      stride=$(cat $stridePath)
      maxw=$(cat $maxWidthPath)

      # 1. Extract every frame, coalesced (so each PNG is a complete
      #    image, not a delta), composited onto solid black to drop
      #    any alpha channel, and downscaled to maxWidth keeping
      #    aspect. The black background matters: the source GIF's
      #    later frames are placed over a transparent canvas, and
      #    Plymouth renders alpha as black anyway — but flattening
      #    here guarantees consistent dimensions and no transparent
      #    pixels that could cause flicker on some renderers.
      magick ${./assets/infinite.gif} \
        -coalesce \
        -background black \
        -alpha remove -alpha off \
        -resize "''${maxw}x>" \
        $out/raw-%04d.png

      # 2. Drop frame 0. The source GIF's first frame is fully black
      #    (the animation fades in from black), so keeping it would
      #    cause a visible black flash every loop iteration.
      rm -f $out/raw-0000.png

      # 3. Keep every Nth frame from what's left, renumber from 0.
      i=0
      kept=0
      for f in $(ls $out/raw-*.png | sort); do
        if [ $((i % stride)) -eq 0 ]; then
          mv "$f" "$(printf "$out/frame-%04d.png" $kept)"
          kept=$((kept + 1))
        else
          rm "$f"
        fi
        i=$((i + 1))
      done

      # 4. Quantize PNGs to 8-bit palette (~50–80% size reduction)
      #    and strip metadata. We do NOT pass --skip-if-larger so
      #    every frame gets a consistent palette/encoding — mixing
      #    quantized and unquantized frames can cause subtle visual
      #    pops when Plymouth swaps between them.
      pngquant --ext .png --force --quality=60-85 --strip \
        $out/frame-*.png || true

      echo "infinite-frames: kept $kept frames" >&2
      du -sh $out >&2
    '';

  infiniteTheme = pkgs.runCommand "plymouth-theme-infinite" { } ''
    mkdir -p $out/share/plymouth/themes/infinite
    cp ${./theme}/infinite.plymouth $out/share/plymouth/themes/infinite/
    cp ${./theme}/infinite.script   $out/share/plymouth/themes/infinite/
    cp ${infiniteFrames}/frame-*.png $out/share/plymouth/themes/infinite/
  '';

in
{
  options.ringofstorms.plymouth = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the custom 'infinite' Plymouth boot/shutdown splash.";
    };

    frameStride = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = ''
        Keep every Nth frame from the source GIF. The source has 541
        frames; stride 12 keeps ~45 frames (~4.5 s loop at the script's
        10 fps playback). Lower = smoother but larger initrd; higher =
        choppier but smaller. Each kept PNG adds ~10–40 KB to initrd
        after pngquant. To change playback speed, edit `fps` in
        infinite.script (not this stride).
      '';
    };

    maxWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1920;
      description = ''
        Maximum frame width in pixels. Frames wider than this are
        downscaled; narrower frames are left alone (the `>` qualifier
        in ImageMagick). Smaller = smaller initrd, blurrier on hi-DPI.
      '';
    };

    quiet = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Suppress kernel and udev log spam so the splash is clean.
        Esc still toggles between splash and live logs at runtime
        (Plymouth's built-in behavior; we don't pass anything that
        would disable it).
      '';
    };

    earlyKms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "i915" ];
      example = [ "amdgpu" ];
      description = ''
        KMS driver modules to force-load early in initrd so Plymouth
        has a DRM device to render against from the very first frame.

        Without this, Plymouth's framebuffer-only fallback path
        sometimes loses the race against the kernel's TTY/journal
        output, producing a text-mode boot even when the splash is
        otherwise fully configured. Loading the GPU driver in initrd
        ensures DRM is up before plymouth-start.service runs.

        Defaults to [ "i915" ] (Intel iGPUs, used on juni/gp3/i001).
        Override per-host:
          - NVIDIA proprietary: [ "nvidia_drm" ] (also requires
            nvidia kernel modules in initrd; see hosts/joe).
          - AMD: [ "amdgpu" ]
          - Empty list disables this and relies on simpledrm/efifb.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.plymouth = {
      enable = true;
      theme = "infinite";
      themePackages = [ infiniteTheme ];
    };

    # Splash on by default, kernel logs hidden but recoverable via Esc.
    # We deliberately do NOT set `rd.systemd.show_status=false` or
    # `systemd.show_status=false` — those would disable the Esc toggle.
    boot.kernelParams = lib.mkIf cfg.quiet [
      "quiet"
      "loglevel=3"
      "rd.udev.log_level=3"
      "udev.log_level=3"
      "vt.global_cursor_default=0"
      # `splash` is added by boot.plymouth automatically.
    ];

    boot.consoleLogLevel = lib.mkIf cfg.quiet 0;
    boot.initrd.verbose  = lib.mkIf cfg.quiet false;

    # Force-load the GPU driver in initrd so DRM is available before
    # plymouth-start.service runs. Without this Plymouth races the
    # journal-tee for /dev/console and loses, producing a text-mode
    # boot. Shutdown still works because by then the driver is loaded.
    boot.initrd.kernelModules = cfg.earlyKms;

    # Plymouth requires systemd-initrd for clean integration. The
    # impermanence module already enables this; assert here so a
    # non-impermanence host enabling Plymouth gets a clear failure
    # instead of a silent broken splash.
    assertions = [
      {
        assertion = config.boot.initrd.systemd.enable;
        message = ''
          ringofstorms.plymouth requires boot.initrd.systemd.enable = true.
          Either enable the impermanence module (which enables it) or set
          this directly in your host config.
        '';
      }
    ];
  };
}
