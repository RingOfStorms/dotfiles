# Guest config: settings copied verbatim from hosts/h001/mods/searx.nix.
{ pkgs, fleetNet, ... }:
let
  secretKeyEnvFile = "/var/lib/searx/secret-key.env";
in
{
  system.stateVersion = "24.11";

  # Same ids as on h001 bare metal, so the copied files keep working.
  users.users.searx.uid = 983;
  users.groups.searx.gid = 971;

  services.searx = {
    enable = true;
    openFirewall = false;
    environmentFile = secretKeyEnvFile;
    settings = {
      server = {
        bind_address = fleetNet.bindAddress;
        port = 8889;
        secret_key = "$SEARX_SECRET_KEY";
      };
      search = {
        formats = [
          "html"
          "json"
        ];
        safe_search = 1;
      };
      outgoing = {
        request_timeout = 10.0;
        max_request_timeout = 15.0;
      };
    };
  };

  systemd.services.searx-init = {
    after = [ "searx-secret-key.service" ];
    requires = [ "searx-secret-key.service" ];
  };

  # SearXNG refuses its upstream placeholder secret. Keep a local random key
  # persistent across restarts without putting it in the Nix store.
  systemd.services.searx-secret-key = {
    description = "Generate SearXNG secret key on first boot";
    before = [ "searx-init.service" ];
    requiredBy = [ "searx-init.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      umask 077
      install -d -m 0750 -o searx -g searx /var/lib/searx
      if [ ! -s ${secretKeyEnvFile} ]; then
        key=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        printf 'SEARX_SECRET_KEY=%s\n' "$key" > ${secretKeyEnvFile}
      fi
    '';
  };
}
