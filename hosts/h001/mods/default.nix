{
  constants,
  lib,
  ...
}:
{
  imports =
    # The media stack runs either here or in the `arr` floating container.
    (
      if constants.services.nixarr.inContainer then
        [ ./arr-nginx.nix ]
      else
        [
          ./nixarr.nix
          ./media-integrity.nix
          ./kavita.nix
        ]
    )
    ++ [
      ./litellm.nix
      ./hardware-transcoding.nix
      ./monitoring_hub.nix
      ./openwebui.nix
      ./searx.nix
      ./trilium.nix
      ./oauth2-proxy.nix
      ./n8n.nix
      ./postgresql.nix
      ./sec.nix
      ./homepage-dashboard.nix
      # ./vault.nix
      ./puzzles.nix
      ./etebase.nix
      ./restic-backup.nix
    ];
}
