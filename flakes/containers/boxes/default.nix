{ buildGoModule, lib, makeWrapper, openssh, zstd, gnutar }:
buildGoModule {
  pname = "boxes";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # standard library only
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ zstd ]; # transfer tests run real tar/zstd pipelines
  postInstall = ''
    wrapProgram $out/bin/boxes --suffix PATH : ${lib.makeBinPath [ openssh zstd gnutar ]}
  '';
  meta.mainProgram = "boxes";
}
