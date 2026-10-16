# Constants for h003 (containers host; was the router until 2026-10-15, see
# hosts/h005/readme.md). Re-imaged onto bcachefs root + impermanence.
{
  host = {
    name = "h003";
    # Assigned by headscale on the 2026-10-16 re-image (was 100.64.0.14).
    overlayIp = "100.64.0.4";
    primaryUser = "luser";
    stateVersion = "26.05";
  };
}
