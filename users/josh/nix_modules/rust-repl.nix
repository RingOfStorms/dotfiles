{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.evcxr ];
  environment.shellAliases = {
    rust = "evcxr";
  };
}
