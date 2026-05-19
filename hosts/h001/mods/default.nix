{
  ...
}:
{
  imports = [
    ./litellm.nix
    # Waiting on https://github.com/maximhq/bifrost/pull/2054 to be merged/released (github provider support)
    # ./bifrost.nix
    ./portkey.nix
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
