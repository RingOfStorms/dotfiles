# The h001 media stack (nixarr: jellyfin, sonarr, radarr, prowlarr, bazarr,
# sabnzbd, transmission behind the wg VPN netns, seerr, shelfmark,
# audiobookshelf, recyclarr) plus kavita and the media-integrity scanner,
# as one container: `containers stop arr` / `start arr` takes it all down/up.
# See README.md (cutover runbook, NAS guard).
{
  name = "arr";
  kind = "nixos";
  host = "h001";
  description = "nixarr media stack + kavita + media-integrity";
  # Media lives on the h002 NAS (bound in, not backed up here); jellyfin
  # transcodes on the Intel iGPU.
  requires = [
    "nfs-h002"
    "intel-qsv"
  ];
  persist = {
    nixarr = "/var/lib/nixarr";
    kavita = "/var/lib/kavita";
    media-integrity = "/var/lib/media-integrity";
    sabnzbd-secrets = "/var/lib/sabnzbd-secrets";
    recyclarr = "/var/lib/recyclarr";
    nixos = "/var/lib/nixos";
  };
  # Host network: sabnzbd, shelfmark, audiobookshelf are reached directly;
  # 51820 is the transmission peer port (DNAT'd into the wg netns).
  tcpPorts = [
    6336
    8087
    9292
    51820
  ];
  udpPorts = [ 51820 ];
  # jellyfin/seerr/kavita/media-health vhosts stay in the h001 host config
  # (hosts/h001/mods/arr-nginx.nix); ports are unchanged on the host network.
  nginx = null;
  backupHook = null;
  attach = null;
}
