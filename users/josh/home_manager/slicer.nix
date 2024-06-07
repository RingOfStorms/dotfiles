{ pkgs, ... }:
let
  orca-slicer-fix = pkgs.stdenv.mkDerivation {
    name = "orca-slicer";
    buildInputs = [ pkgs.makeWrapper ];
    unpackPhase = "true";
    buildPhase = ''
      mkdir -p $out/bin
      makeWrapper ${pkgs.orca-slicer}/bin/orca-slicer $out/bin/orca-slicer \
        --set WEBKIT_DISABLE_DMABUF_RENDERER 1
    '';

    installPhase = ''
      mkdir -p $out/share/applications
      cat > $out/share/applications/orca-slicer.desktop <<EOF
      [Desktop Entry]
      Name=Orca Slicer
      Comment=3D printing slicer
      Exec=$out/bin/orca-slicer
      Icon=orca-slicer
      Terminal=false
      Type=Application
      Categories=Graphics;3DGraphics;
      EOF
    '';
  };
in
{
  home.packages = with pkgs; [
    prusa-slicer
    orca-slicer-fix
  ];
}
