# The media stack (nixarr: jellyfin, sonarr, radarr, prowlarr, bazarr,
# sabnzbd, seerr, shelfmark, recyclarr) plus kavita and the media-integrity scanner,
# as one container: `containers stop arr` / `start arr` takes it all down/up.
# See README.md (NAS guard).
{
  name = "arr";
  kind = "nixos";
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
  # No raw ports: every UI is a route below.
  net = {
    private = true;
    index = 16;
  };
  tcpPorts = [ ];
  udpPorts = [ ];
  # jellyfin + media: public via the o002 edge; books (kavita): tailnet only.
  # Each app has its own accounts (TV/mobile clients), so no gate.
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
  };
  # /media-health/ on h001.net lives in hosts/h001/mods/arr-nginx.nix (a
  # static alias of the persist dir, not a backend).
  backupHook = null;
  attach = null;
}
