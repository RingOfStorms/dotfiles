# Opengist (https://github.com/thomiceli/opengist): gist.joshuabell.xyz.
#
# Data: /srv/containers/opengist/data (sqlite db, git repos, index, secret
# key, sessions). Files are owned by uid 1000, the image's runtime user; the
# idmapped volume keeps that on disk.
{
  name = "opengist";
  kind = "podman";
  description = "Opengist pastebin (gist.joshuabell.xyz)";

  persist = {
    data = "/opengist";
  };

  # opengist uses local auth only, no external APIs needed.
  internet = false;

  # Static IP on the shared fleet-noinet bridge (10.89.250.102, offset past
  # the .1 gateway and podman's dynamic-IPAM low range): host nginx
  # proxies straight to it, so opengist is not reachable on the host's
  # loopback by every other local process. index is fleet-wide unique
  # within kind = "podman" (checkNetIndexes).
  net = {
    private = true;
    index = 2;
  };

  podman = {
    # Pinned; bump deliberately (opengist migrates its db on upgrade, take a
    # `cnt backup opengist` first).
    image = "ghcr.io/thomiceli/opengist:1.10.0@sha256:b3ae8c4614fcfc3099ed08317f0113444f314d3d390e89161cff9b673729d191";
    # No publish: reached only via the bridge IP (net.private above).
    environment = {
      OG_LOG_LEVEL = "info";
    };
  };

  # SQLite: stop for a consistent backup (`cnt backup opengist` asks).

  routes.web = {
    group = "Productivity";
    port = 6157;
    name = "gist";
    exposure = "public";
    auth = "native";
    maxBody = "64m";
  };
}
