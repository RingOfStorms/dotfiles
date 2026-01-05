{ config, lib, ... }:
let
  cfg = config.ringofstorms.secretsBao;
  secrets = cfg.secrets or { };
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge (lib.mapAttrsToList (_: s: s.configChanges { path = s.path; }) secrets)
  );
}
