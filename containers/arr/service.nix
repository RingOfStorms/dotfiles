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
  # Media lives on the h004 NAS (bound in, not backed up here); jellyfin
  # transcodes on the Intel iGPU.
  requires = [
    "nfs-h004"
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
  # jellyfin + media: public via the o002 edge (ROUTING-PLAN §2.3); books
  # (kavita): tailnet only. Each app has its own
  # accounts (TV/mobile clients), so no gate. maxBody 500m = h001's old
  # global client_max_body_size these vhosts inherited.
  routes = {
    jellyfin = {
      name = "jellyfin";
      port = 8096;
      exposure = "public";
      auth = "native";
      maxBody = "500m";
    };
    media = {
      name = "media"; # seerr
      port = 5055;
      exposure = "public";
      auth = "native";
      maxBody = "500m";
    };
    books = {
      name = "books"; # kavita
      port = 5000;
      exposure = "tailnet";
      auth = "native";
      maxBody = "500m";
    };
  };
  # The :9091 transmission proxy and /media-health/ on h001.net stay in
  # hosts/h001/mods/arr-nginx.nix (not routes: a netns upstream and a static alias).
  backupHook = null;
  attach = null;
}
