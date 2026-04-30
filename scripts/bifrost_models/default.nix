# buildGoModule wrapper for the bifrost-models regen script.
#
# Stdlib-only — no external Go deps, hence `vendorHash = null`. If we ever
# pull in a third-party package, replace null with the SHA bun produces
# (set to lib.fakeHash, build, copy the "got:" hash from the error).
{ buildGoModule }:

buildGoModule {
  pname = "bifrost-models";
  version = "0.1.0";
  src = ./go;
  vendorHash = null;
  meta.mainProgram = "bifrost-models";
}
