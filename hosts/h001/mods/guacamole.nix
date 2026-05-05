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
#                  guacd (translates SSH ↔ HTML5)
#                       │
#                       │  SSH over tailscale0 (or LAN for non-tailnet hosts)
#                       ▼
#                  every host in fleet.hosts (sshd)
#
# Auth: oauth2-proxy authenticates against Zitadel and forwards
#       X-User: <user> to the backend. The guacamole-auth-header
#       extension reads X-User and trusts it as the authenticated
#       identity. user-mapping.xml then provides the connection list
#       for that user.
#
# Connections are SSH-only for now. Public-key auth uses the fleet-wide
# `nix2nix_2026-03-15` ed25519 key, which is already authorized on
# every host's authorized_keys (set by fleet.mkHost via global.sshPubKey).
# RDP support has been removed pending a working live-mirroring KRDP
# build for Plasma — see the prior history of this module if/when we
# revisit that.
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

  # ── Zitadel users authorized to use Guacamole ──────────────────
  # Each entry produces an <authorize username="..."> block. The
  # `username` MUST match what oauth2-proxy puts into the X-User
  # header (defaults to the user's email, see services.oauth2-proxy
  # in mods/oauth2-proxy.nix). Add more users as you grant the
  # `remote-desktop` Zitadel project role to additional people.
  authorizedUsers = [
    "abc@joshuabell.xyz"
  ];

  # ── Hosts that should appear as SSH connections in Guacamole ───
  # Pulls from fleet.hosts. We include only deployable hosts —
  # `t` and `l002` are SSH-config aliases for external accounts
  # (work box, etc.) where the fleet's nix2nix key isn't authorized
  # in authorized_keys. Hitting them from Guacamole would just hang
  # at the SSH key auth step.
  #
  # For each remaining host, prefers overlayIp (tailnet) over lanIp
  # over publicIp — h001 is on the tailnet and trusts that interface,
  # so reaching hosts via tailscale is both available and cheaper
  # than going out the LAN gateway.
  isReachable = h: h ? overlayIp || h ? lanIp || h ? publicIp;
  pickIp = h:
    if h ? overlayIp then h.overlayIp
    else if h ? lanIp then h.lanIp
    else h.publicIp;
  sshHosts = lib.filterAttrs
    (_: h: (h ? user) && isReachable h)
    fleet.deployableHosts;

  # Render a single <connection> XML element for one host. Uses
  # the inline `private-key` param so guacd doesn't need filesystem
  # access to the key — vault-agent templates the key in at render
  # time. Indented to slot inside an <authorize> block.
  mkSshConnection = name: h: ''
            <connection name=${escapeXmlAttr "${name} (${h.user}@${pickIp h})"}>
              <protocol>ssh</protocol>
              <param name="hostname">${pickIp h}</param>
              <param name="port">22</param>
              <param name="username">${h.user}</param>
              <param name="private-key">{{ .Data.data.value }}</param>
              <param name="color-scheme">gray-black</param>
              <param name="font-size">12</param>
            </connection>'';

  # Tiny helper to XML-attribute-escape a string. user/IP fields are
  # under our control so they won't contain quotes or angle brackets,
  # but it's cheap insurance.
  escapeXmlAttr = s:
    "\"" + (lib.replaceStrings [ "&" "<" ">" "\"" ] [ "&amp;" "&lt;" "&gt;" "&quot;" ] s) + "\"";

  # Render one <authorize> block per authorized user. Every authorized
  # user gets the same connection list — we don't (yet) have a need
  # for per-user connection ACLs since the Zitadel role check at the
  # edge already gates access to Guacamole entirely.
  connectionsBlock = lib.concatStringsSep "\n"
    (lib.mapAttrsToList mkSshConnection sshHosts);

  mkAuthorizeBlock = email: ''
          <authorize username=${escapeXmlAttr email} password="header-auth-bypass">
${connectionsBlock}
          </authorize>'';

  authorizeBlocks = lib.concatStringsSep "\n"
    (map mkAuthorizeBlock authorizedUsers);
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

  # ── Vault-agent template: render user-mapping.xml at runtime ──
  # The placeholder password on <authorize> is bypassed because
  # header-auth provides the authenticated identity before
  # user-mapping's password check runs. The per-connection
  # `private-key` is templated in from the fleet-wide nix2nix
  # ed25519 key (already authorized on every host's authorized_keys
  # via fleet.mkHost + global.sshPubKey).
  #
  # The `username` attribute on <authorize> must match what
  # oauth2-proxy puts into the X-User header (defaults to email).
  # See `authorizedUsers` in the let-binding above.
  #
  # The secret name reuses the existing per-host
  # `nix2nix_2026-03-15` KV path on h001 — no new secret to provision.
  ringofstorms.secretsBao.secrets = {
    # Sibling secret that renders the user-mapping.xml file. The
    # nix2nix_2026-03-15 KV path is also rendered separately by
    # mkAutoSecrets for the primary user's SSH config — having a
    # second secretsBao entry that READS the same kvPath but
    # renders to a different file with different ownership is
    # exactly what's needed here.
    guacamole-user-mapping = {
      kvPath = "kv/data/machines/high-trust/nix2nix_2026-03-15";
      path = "${guacamoleHome}/user-mapping.xml";
      owner = "tomcat";
      group = "tomcat";
      mode = "0640";
      softDepend = [ "tomcat" ];
      # We use the nix2nix KV path here directly. The inner
      # {{ .Data.data.value }} substitution is referenced from
      # mkSshConnection above when building each connection's
      # <param name="private-key"> element.
      template = ''
        {{- with secret "kv/data/machines/high-trust/nix2nix_2026-03-15" -}}
        <user-mapping>
${authorizeBlocks}
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
    # Edge-level gating: only Zitadel users with the `remote-desktop`
    # project role can pass oauth2-proxy. Maps to flatRolesClaim per
    # the OIDC client config in mods/oauth2-proxy.nix. Users without
    # this role get a 403 at nginx — they never reach Guacamole.
    allowed_groups = [ "remote-desktop" ];
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
