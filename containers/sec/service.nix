# sec — the fleet secrets manager server (secrets.joshuabell.xyz).
# Was hosts/h001/mods/sec.nix (bare-metal systemd unit). Host network:
# 127.0.0.1:8300 behind nginx, same as before.
#
# Bootstrap: every host's sec-agent (h001's included) fetches from here and
# logs in via zitadel. Agents keep their hydrated cache, so a short outage is
# harmless; a lost db.key is not (break-glass copy is offline + in restic).
{
  name = "sec";
  kind = "nixos";
  description = "sec secrets manager server (secrets.joshuabell.xyz)";
  host = "h001";

  persist = {
    # sec.db + db.key (0400 root). The SQLite file is snapshotted by the
    # host's restic prepare step (generic /srv/containers scan); db.key is
    # backed up as a plain file from here.
    data = "/var/lib/secrets_manager";
    nixos = "/var/lib/nixos";
  };

  # Dumb proxy, as the old module vhost: the origin authenticates every route.
  # Public via edge (o002): a new machine reads its headscale join key over
  # the internet before it is on the tailnet (see o002/nginx.nix).
  routes.web = {
    group = "Identity & Security";
    icon = "https://api.iconify.design/game-icons/locked-chest.svg?color=%23e0b25c";
    port = 8300;
    name = "secrets";
    exposure = "public";
    auth = "native-oidc";
    maxBody = "64k";
  };
}
