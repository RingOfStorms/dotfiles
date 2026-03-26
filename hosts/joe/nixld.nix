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
}
