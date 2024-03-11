# This nix file is just a fix for a really stupid lay-outed keyboard I bought that I
# only use with the gpd pocket 3. Probably not relevant to anyone else
#
# Keyboard in question: https://www.walmart.com/ip/R-Go-Split-Ergonomic-Keyboard-QWERTY-US-Black-Wired-USB-Keyboard-Spilt-Wired-Windows-Linux/452297950
# R-Go Split Break Keyboard (maybe the walmart one is a fake since their real site does not have the same layout)
#    https://www.r-go-tools.com/ergonomic-keyboard/r-go-split-break/
{ config, lib, pkgs, ... }:

let
  rgo_keyboard_vid = "0911";
  rgo_keyboard_pid = "2188";
  rgo_hub_vid = "05e3";
  rgo_hub_pid = "0608";
in
{
  services.keyd = {
    enable = true;
    # `keyd monitor` to get new keys to remap
    keyboards = {
      rgo_sino_keyboard = {
        ids = [ "0911:2188" "05e3:0608" ];
        settings = {
          main = {
            # Backslash is in place of the enter key's normal position, so setting it to enter
            "\\" = "enter";
            # This keyboard has a strange extra key that outputs < and > characters. It has the
            # backslash key printed on it though, conveniently, so we will just map this to backslash
            # since it does not affect how I use left shift (which it takes half the space of)
            "102nd" = "\\";
          };
        };
      };
    };
  };
}
