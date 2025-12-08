{ pkgs, ... }:
{
  programs = {
    nix-ld = {
      enable = true;
      libraries = with pkgs; [
        icu
        gmp
        glibc
        openssl
        stdenv.cc.cc
      ];
    };
  };
  environment.shellAliases = {
    "oc" =
      "all_proxy='' http_proxy='' https_proxy='' /home/josh/other/opencode/node_modules/opencode-linux-x64/bin/opencode";
    "occ" = "oc -c";
  };
}
