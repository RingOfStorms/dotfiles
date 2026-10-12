{ buildGoModule, lib, makeWrapper, openssh, zstd, gnutar, util-linux }:
buildGoModule {
  pname = "containers";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # standard library only
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ zstd util-linux ]; # transfer tests run real tar/zstd pipelines and flock
  postInstall = ''
    wrapProgram $out/bin/containers --suffix PATH : ${lib.makeBinPath [ openssh zstd gnutar ]}
  '';
  meta.mainProgram = "containers";
}
