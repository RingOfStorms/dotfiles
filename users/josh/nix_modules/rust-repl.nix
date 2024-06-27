{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ evcxr rustc ];
  environment.shellAliases = {
    rust = "evcxr";
  };
}
