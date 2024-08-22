{ ... }:
{
  programs.zsh.shellAliases = {
    # Nix deprecations
    nix-hash = "echo 'The functionality of nix-hash may be covered by various subcommands or options in the new `nix` command.'";
    nix-build = "echo 'Use `nix build` instead.'";
    nix-info = "echo 'Use `nix flake info` or other `nix` subcommands to obtain system and Nix information.'";
    nix-channel = "echo 'Channels are being phased out in favor of flakes. Use `nix flake` subcommands.'";
    nix-instantiate = "echo 'Use `nix eval` or `nix-instantiate` with flakes.'";
    nix-collect-garbage = "echo 'Use `nix store gc` instead.'";
    nix-prefetch-url = "echo 'Use `nix-prefetch` or fetchers in Nix expressions.'";
    nix-copy-closure = "echo 'Use `nix copy` instead.'";
    nix-shell = "echo 'Use `nix shell` instead.'";
    # nix-daemon # No direct replacement: The Nix daemon is still in use and managed by the system service manager.
    nix-store = "echo 'Use `nix store` subcommands for store operations.'";
    nix-env = "echo 'Use `nix profile` instead'";
  };
}
