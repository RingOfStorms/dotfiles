{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemd,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
}:
# Upstream ships only prebuilt Electron bundles; its curl installer unpacks the same tarball under ~/.local.
stdenv.mkDerivation (finalAttrs: {
  pname = "terminal-browser";
  version = "0.13.1";

  src = fetchurl {
    url = "https://terminal-browser.sh/install/dl/stable/v${finalAttrs.version}/terminal-browser-linux-x64.tar.gz";
    hash = "sha256-IeMqVSEiSeMPo9/aHD7egrG/b4L5PvROtjsbYl6g1Wc=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libdrm
    libgbm
    libxkbcommon
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
  ];

  # Chromium dlopens these instead of linking them.
  runtimeDependencies = [
    libGL
    (lib.getLib systemd)
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/terminal-browser" "$out/bin"
    cp -r . "$out/share/terminal-browser"
    # The launcher follows its own symlinks to derive TERMINAL_BROWSER_DIST_ROOT.
    ln -s "$out/share/terminal-browser/bin/terminal-browser" "$out/bin/terminal-browser"
    runHook postInstall
  '';

  meta = {
    description = "A real browser that runs inside your terminal";
    homepage = "https://github.com/zenbu-labs/terminal-browser";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "terminal-browser";
  };
})
