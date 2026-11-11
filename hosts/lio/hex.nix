{ inputs, lib, pkgs, ... }:
let
  # Hex's dependencies need a newer Rust than lio's nixpkgs currently ships.
  rustPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [ inputs.rust-overlay.overlays.default ];
  };
  rustToolchain = rustPkgs.rust-bin.stable.latest.default;
  rustPlatform = rustPkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
in
{
  # Hex's Linux shortcuts need a non-modifier key. Reserve Right Alt for
  # dictation by making it F19 in the US layout used by Plasma on lio.
  services.xserver.xkb = {
    extraLayouts.us-hex = {
      description = "US with Right Alt for Hex";
      languages = [ "eng" ];
      symbolsFile = pkgs.writeText "us-hex-symbols" ''
        default partial alphanumeric_keys modifier_keys
        xkb_symbols "us-hex" {
          include "us(basic)"
          replace key <RALT> { [ F19 ] };
        };
      '';
    };
    layout = lib.mkForce "us-hex";
  };

  home-manager.users.josh = {
    imports = [ inputs.hex.homeManagerModules.hex ];

    programs.plasma.input.keyboard.layouts = lib.mkForce [ { layout = "us-hex"; } ];
    programs.hex = {
      enable = true;
      package = pkgs.callPackage "${inputs.hex}/nix/package.nix" { inherit rustPlatform; };
      autostart = true;
      installModel = true;
      settings = {
        shortcut_mode = "hold";
        double_tap_lock = false;
        double_tap_only = false;
      };
      shortcut = "f19";
    };
  };
}
