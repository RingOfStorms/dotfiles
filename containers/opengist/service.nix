# Opengist (https://github.com/thomiceli/opengist): gist.joshuabell.xyz.
# Was a host oci-container on h001 (hosts/h001/containers/opengist.nix).
#
# Data: /srv/containers/opengist/data = the old /var/lib/opengist (sqlite
# db, git repos, index, secret key, sessions). Files are owned by uid 1000,
# the image's runtime user; the idmapped volume keeps that on disk.
{
  name = "opengist";
  kind = "podman";
  description = "Opengist pastebin (gist.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/opengist";
  };

  podman = {
    # Pinned; bump deliberately (opengist migrates its db on upgrade, take a
    # `cnt backup opengist` first).
    image = "ghcr.io/thomiceli/opengist:1.10.0";
    ports = [ "6157:6157" ]; # 127.0.0.1 only; nginx below fronts it
    environment = {
      OG_LOG_LEVEL = "info";
    };
  };

  # SQLite: stop for a consistent backup (`cnt backup opengist` asks).

  # o002 terminates TLS for the public name and proxies to h001:80 over the
  # tailnet; LAN/tailnet clients may hit h001:443 directly (wildcard cert).
  routes.web = {
    port = 6157;
    name = "gist";
    exposure = "public";
    auth = "native";
    maxBody = "64m";
  };
}
