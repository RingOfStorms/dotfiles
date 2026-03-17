{
  ...
}:
{
  imports = [
    ./litellm.nix
    ./litellm-public.nix
    ./nixarr.nix
    ./hardware-transcoding.nix
    ./monitoring_hub.nix
    ./youtarr.nix
    # ./openwebui.nix # Replaced by chat-ui (containers/chat-ui.nix)
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
