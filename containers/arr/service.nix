# The h001 media stack (nixarr: jellyfin, sonarr, radarr, prowlarr, bazarr,
# sabnzbd, transmission behind the wg VPN netns, seerr, shelfmark,
# recyclarr) plus kavita and the media-integrity scanner,
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
  # Private network (ROUTING-PLAN §8 step 5): guest 10.233.16.2. The guest
  # owns the `wg` VPN netns (transmission); 51820 is reached over the VPN
  # tunnel only. No raw ports: every UI is a route below.
  net = {
    private = true;
    index = 16;
  };
  tcpPorts = [ ];
  udpPorts = [ ];
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
    shelfmark = {
      name = "shelfmark"; # book/audiobook acquisition UI, listens on 127.0.0.1
      port = 8087;
      exposure = "tailnet";
      auth = "none";
    };
    books = {
      name = "books"; # kavita
      port = 5000;
      exposure = "tailnet";
      auth = "native";
      maxBody = "500m";
    };
    # *arr UIs: tailnet only (no LAN, no o002), no login. The apps see the
    # host veth (10.233.0.1) as the client, a local address, so their own
    # auth (DisabledForLocalAddresses) stays out of the way.
    sonarr = {
      name = "sonarr";
      port = 8989;
      exposure = "tailnet";
      auth = "none";
      group = "Media Automation";
    };
    radarr = {
      name = "radarr";
      port = 7878;
      exposure = "tailnet";
      auth = "none";
      group = "Media Automation";
    };
    bazarr = {
      name = "bazarr";
      port = 6767;
      exposure = "tailnet";
      auth = "none";
      group = "Media Automation";
    };
    prowlarr = {
      name = "prowlarr";
      port = 9696;
      exposure = "tailnet";
      auth = "none";
      group = "Media Automation";
    };
    sabnzbd = {
      name = "sabnzbd";
      port = 6336;
      exposure = "tailnet";
      auth = "none";
      group = "Media Automation";
      maxBody = "100m"; # nzb uploads
    };
    transmission = {
      name = "transmission";
      port = 9091; # guest DNATs it into the wg netns (192.168.15.1)
      exposure = "tailnet";
      auth = "none";
      group = "Media Automation";
      maxBody = "100m"; # .torrent uploads
    };
  };
  # /media-health/ on h001.net stays in hosts/h001/mods/arr-nginx.nix (a
  # static alias of the persist dir, not a backend).
  backupHook = null;
  attach = null;
}
