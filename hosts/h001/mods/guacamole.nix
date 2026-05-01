# Apache Guacamole — clientless HTML5 remote desktop gateway.
#
# Architecture:
#   Browser ──HTTPS──▶ nginx (oauth2-proxy auth_request)
#                       │
#                       ▼
#                  Tomcat (guacamole webapp, :8080)
#                       │
#                       │  guacamole protocol (loopback :4822)
#                       ▼
#                  guacd (translates RDP/VNC/SSH ↔ HTML5)
#                       │
#                       │  RDP/SSH over tailscale0
#                       ▼
#                  joe (KRDP), other hosts (sshd)
#
# Auth: oauth2-proxy authenticates against Zitadel and forwards
#       X-User: <user> to the backend. The guacamole-auth-header
#       extension reads X-User and trusts it as the authenticated
#       identity. user-mapping.xml then provides the connection list
#       for that user.
#
# Why we override GUACAMOLE_HOME to /var/lib/guacamole instead of using
# the default /etc/guacamole (which the nixpkgs module manages):
#   - /etc/guacamole entries are nix-store symlinks (read-only).
#   - vault-agent needs to write user-mapping.xml at runtime so we can
#     interpolate per-connection passwords without putting them in nix.
#   - GUACAMOLE_HOME must contain ALL config (properties, mappings,
#     extensions). So we stage everything under /var/lib/guacamole.
{
  config,
  lib,
  pkgs,
  constants,
  fleet,
  ...
}:
let
  domain = fleet.global.domain;
  guacDomain = "guac.${domain}";

  # Auth-header extension. Must match the bundled guacamole-client
  # version exactly — Guacamole refuses to load extensions with
  # mismatched manifest versions. Hash is for 1.6.0; bump both when
  # nixpkgs ships a newer guacamole-client.
  guacVersion = "1.6.0";
  authHeaderExtension = pkgs.fetchurl {
    url = "https://archive.apache.org/dist/guacamole/${guacVersion}/binary/guacamole-auth-header-${guacVersion}.tar.gz";
    hash = "sha256-VMbqlEqrUVO9ogQB+ihAASitiWBrVwJ77iEnMntl+Vg=";
  };

  # Fail the build if the bundled webapp version drifts away from the
  # extension version — they need to be kept in lockstep.
  guacVersionMatches = pkgs.guacamole-client.version == guacVersion;

  # GUACAMOLE_HOME staging dir — extensions only (the .properties and
  # user-mapping.xml are placed at runtime by tmpfiles + vault-agent).
  guacHomeStatic = pkgs.runCommand "guacamole-home-static" { } ''
    mkdir -p $out/extensions
    tar -xzf ${authHeaderExtension} \
      -C $out/extensions \
      --strip-components=1 \
      --wildcards '*/guacamole-auth-header-*.jar'
  '';

  guacamoleHome = "/var/lib/guacamole";

  # guacamole.properties content. Written via environment.etc into the
  # static GUACAMOLE_HOME and symlinked from guacHome at runtime so
  # editing it is a normal nixos-rebuild.
  guacPropertiesText = ''
    guacd-hostname: 127.0.0.1
    guacd-port: 4822

    # Header authentication — trust X-User from oauth2-proxy.
    http-auth-header: X-User
  '';
  guacPropertiesFile = pkgs.writeText "guacamole.properties" guacPropertiesText;
in
{
  assertions = [{
    assertion = guacVersionMatches;
    message = ''
      hosts/h001/mods/guacamole.nix: pkgs.guacamole-client version
      (${pkgs.guacamole-client.version}) does not match the pinned
      extension version (${guacVersion}). Update both the guacVersion
      let-binding and the auth-header tarball hash to match the new
      release.
    '';
  }];

  # ── guacd (the protocol translator daemon) ─────────────────────────
  services.guacamole-server = {
    enable = true;
    host = "127.0.0.1";
    port = 4822;
  };

  # ── guacamole webapp (Tomcat) ──────────────────────────────────────
  # We enable the client module purely to get Tomcat + the .war
  # deployed. We deliberately do NOT use its `settings` /
  # `userMappingXml` options because we're managing GUACAMOLE_HOME
  # ourselves at /var/lib/guacamole.
  services.guacamole-client = {
    enable = true;
    settings = { };       # we provide guacamole.properties directly
  };

  # Bind Tomcat to 127.0.0.1 only. The nixpkgs tomcat module doesn't
  # expose an `address` option for the Connector, and h001 trusts
  # tailscale0 in its firewall (see flakes/common/nix_modules/tailnet),
  # so without this bind anyone on the tailnet could reach
  # h001:8080/guacamole/ directly and bypass oauth2-proxy. Patch
  # server.xml in place after the tomcat module has rendered it.
  systemd.services.tomcat.preStart = lib.mkAfter ''
    cfg="${config.services.tomcat.baseDir}/conf/server.xml"
    if [ -f "$cfg" ] && ! ${pkgs.gnugrep}/bin/grep -q 'address="127.0.0.1"' "$cfg"; then
      ${pkgs.gnused}/bin/sed -i \
        's|<Connector port="8080"|<Connector address="127.0.0.1" port="8080"|' \
        "$cfg"
    fi
  '';

  # Override Tomcat's GUACAMOLE_HOME to point at /var/lib/guacamole.
  systemd.services.tomcat.environment.GUACAMOLE_HOME = guacamoleHome;

  # ── Stage GUACAMOLE_HOME on disk ───────────────────────────────────
  # tmpfiles creates the dirs and symlinks the static parts (extensions
  # dir, guacamole.properties) into place. user-mapping.xml is created
  # separately by vault-agent.
  systemd.tmpfiles.rules = [
    "d ${guacamoleHome}                 0750 tomcat tomcat - -"
    "L+ ${guacamoleHome}/extensions     -    -      -      - ${guacHomeStatic}/extensions"
    "L+ ${guacamoleHome}/guacamole.properties - - - - ${guacPropertiesFile}"
    # user-mapping.xml is not pre-created here — vault-agent renders
    # it. Tomcat tolerates a missing file at startup (no users defined
    # yet); once vault-agent writes it, header-auth picks up users on
    # next login attempt without a Tomcat restart.
  ];

  # ── Vault-agent template: render user-mapping.xml at runtime ───────
  # The placeholder password on <authorize> is bypassed because
  # header-auth provides the authenticated identity before
  # user-mapping's password check runs. The connection-level password
  # IS the real RDP credential and is templated in from openbao.
  #
  # The `username` attribute must match whatever oauth2-proxy puts into
  # the X-User header (i.e. whatever maps to X-Auth-Request-User upstream).
  # With oauth2-proxy defaults, that's the user's *email*. If you change
  # `--user-id-claim` in services.oauth2-proxy, update the username here
  # to match.
  ringofstorms.secretsBao.secrets = {
    "guacamole_joe_krdp_2026-05-01" = {
      path = "${guacamoleHome}/user-mapping.xml";
      owner = "tomcat";
      group = "tomcat";
      mode = "0640";
      softDepend = [ "tomcat" ];
      template = ''
        {{- with secret "kv/data/machines/high-trust/guacamole_joe_krdp_2026-05-01" -}}
        <user-mapping>
          <authorize username="admin@joshuabell.xyz" password="header-auth-bypass">
            <connection name="joe (RDP)">
              <protocol>rdp</protocol>
              <param name="hostname">100.64.0.12</param>
              <param name="port">3389</param>
              <param name="username">josh</param>
              <param name="password">{{ .Data.data.value }}</param>
              <param name="security">nla</param>
              <param name="ignore-cert">true</param>
              <param name="resize-method">display-update</param>
              <param name="enable-wallpaper">true</param>
              <param name="enable-font-smoothing">true</param>
              <param name="color-depth">24</param>
            </connection>
            <connection name="joe (SSH)">
              <protocol>ssh</protocol>
              <param name="hostname">100.64.0.12</param>
              <param name="port">22</param>
              <param name="username">josh</param>
            </connection>
          </authorize>
        </user-mapping>
        {{- end -}}
      '';
    };
  };

  # ── nginx vhost behind oauth2-proxy ────────────────────────────────
  # services.oauth2-proxy.nginx.virtualHosts.<host> wraps the named
  # vhost with auth_request /oauth2/auth and sets X-User from the
  # validated session. The companion services.nginx.virtualHosts entry
  # provides the actual proxyPass — both attrsets target the same
  # vhost name and nginx merges them.
  services.oauth2-proxy.nginx.virtualHosts."${guacDomain}" = {
    # No group restriction yet; SSO login alone is sufficient. Tighten
    # later with `allowed_groups = [ "remote-desktop" ];` once that
    # group exists in Zitadel.
  };

  services.nginx.virtualHosts."${guacDomain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${domain}/key.pem";
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080/guacamole/";
      proxyWebsockets = true;
      extraConfig = ''
        # Guacamole's HTML5 client uses long-lived WebSocket tunnels
        # for the actual remote-desktop stream — bump read timeout so
        # idle sessions don't get culled.
        proxy_read_timeout 1d;
        proxy_buffering off;
      '';
    };
  };
}
