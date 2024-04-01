{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # extras, more for my neovim setup TODO move these into a more isolated place for nvim setup? Should be its own flake probably
    cargo
    rustc
    nodejs_21
    python313
    nodePackages.cspell
    # ripgrep (now in common but will be needed in neovim flake)
  ];
}

