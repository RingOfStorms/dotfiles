{
  ...
}:
{
  imports = [
    ./litellm.nix
    ./nixarr.nix
    # ./monitoring.nix # disabling
    ./monitoring_hub.nix
    ./monitoring_agent.nix
    ./pinchflat.nix
    ./openwebui.nix
    ./trilium.nix
    ./oauth2-proxy.nix
    ./n8n.nix
    ./postgresql.nix
    ./openbao.nix
    # ./vault.nix
  ];
}
