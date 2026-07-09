{
  ...
}:
{
  imports = [
    ./litellm.nix
    ./nixarr.nix
    ./hardware-transcoding.nix
    ./monitoring_hub.nix
    ./openwebui.nix
    ./trilium.nix
    ./oauth2-proxy.nix
    ./n8n.nix
    ./postgresql.nix
    ./openbao
    ./homepage-dashboard.nix
    # ./vault.nix
    ./puzzles.nix
    ./etebase.nix
  ];
}
