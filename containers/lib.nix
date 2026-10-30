# Shared helpers for "floating" services in containers/<app>/.
#
# Every app directory has:
#   service.nix  plain metadata (read by the parent flake and the `containers` CLI)
#   flake.nix    builds the deployable artifact as packages.<system>.default
#
# Two kinds of service:
#   kind = "nixos"   extra-container / systemd-nspawn, NixOS modules inside
#   kind = "podman"  OCI image run by a podman systemd unit
#
# Both use the same persistence model: the root filesystem is thrown away on
# every start. Only the directories listed in `persist` survive. They live on
# the host at /srv/containers/<name>/<key> and are bind-mounted with an idmap.
# With an idmap, the file owners on the host are the same numbers the
# container sees, so there is no host UID ledger. Copying the directory with
# --numeric-owner moves it to any other host.
let
  dataRoot = "/srv/containers";

  # Turn a persist attrset { key = "/path/in/container"; } into a list of
  # { host, container } pairs.
  persistList =
    service:
    map (key: {
      host = "${dataRoot}/${service.name}/${key}";
      container = service.persist.${key};
    }) (builtins.attrNames (service.persist or { }));

  domain = "joshuabell.xyz";

  # hosts/fleet.nix: overlay IPs, trust levels and the one LAN subnet. The
  # single source of truth for the firewall allow-lists below. Same local-tree
  # assumption as the readFile'd snippets further down (consumed as
  # `path:containers` next to hosts/, or via --override-input in the
  # superproject); `import` keeps it lazy, so nothing here evaluates mkHost.
  fleetHosts = import ../hosts/fleet.nix;
  lanSubnet = fleetHosts.global.lanSubnet;

  # ---------------------------------------------------------------- routes
  # ROUTING-PLAN.md §2. Each route is normalized and validated here; any
  # mistake throws at eval time (the inventory, every flake build).
  #
  # Naming: a route called `web` gets the service name (atuin.joshuabell.xyz);
  # any other route gets "<svc>-<route>" (immich-db). Set `name` to override.
  # tcp/udp routes have no name, url or fqdn (no DNS yet; that's fleet-edge).
  routeEnums = {
    proto = [
      "http"
      "tcp"
      "udp"
    ];
    exposure = [
      "local"
      "tailnet"
      "lan"
      "public"
    ];
    auth = [
      "native-oidc"
      "native"
      "oauth2-proxy"
      "none"
    ];
    via = [
      "edge"
      "router"
    ];
  };
  commonRouteKeys = [
    "port"
    "proto"
    "exposure"
    "auth"
    "via"
    "allow"
    "health"
    "icon"
    "group"
    "publicWithoutAuth"
  ];
  httpRouteKeys = [
    "name"
    "websockets"
    "maxBody"
    "buffering"
    "timeouts"
    "requestBuffering"
    "forwardedProto"
    "extraConfig"
    # auth = "oauth2-proxy" only (ROUTING-PLAN §8 step 6)
    "groups"
    "bypass"
  ];

  normalizeRoute =
    svcName: routeName: r:
    let
      where = "${svcName}: routes.${routeName}";
      fail = msg: throw "${where}: ${msg}";
      proto = r.proto or "http";
      isHttp = proto == "http";
      allowedKeys = commonRouteKeys ++ (if isHttp then httpRouteKeys else [ ]);
      unknown = builtins.filter (k: !(builtins.elem k allowedKeys)) (builtins.attrNames r);
      oneOf =
        field: v:
        if builtins.elem v routeEnums.${field} then
          v
        else
          fail "${field} = ${builtins.toJSON v} is not one of ${
            builtins.concatStringsSep ", " routeEnums.${field}
          }";
      exposure = oneOf "exposure" (r.exposure or "local");
      isPublic = exposure == "public";
      auth = if r ? auth then oneOf "auth" r.auth else null;
      via =
        if r ? via then
          (
            if !isPublic then
              fail "via only applies to exposure = \"public\""
            else if !(builtins.isList r.via) || r.via == [ ] then
              fail "via must be a non-empty list"
            else
              map (oneOf "via") r.via
          )
        else if isPublic && isHttp then
          [ "edge" ]
        else if isPublic then
          fail "public ${proto} routes need an explicit via (e.g. [ \"router\" ])"
        else
          [ ];
      name = r.name or (if routeName == "web" then svcName else "${svcName}-${routeName}");
      fqdn = "${name}.${domain}";
      checks = [
        {
          bad = unknown != [ ];
          msg =
            "unknown key(s) ${builtins.concatStringsSep ", " unknown}"
            + (if isHttp then "" else " (http-only knobs and name are not allowed for proto = \"${proto}\")");
        }
        {
          bad = !(r ? port) || !(builtins.isInt r.port) || r.port < 1 || r.port > 65535;
          msg = "port must be an integer 1-65535";
        }
        {
          bad = !(builtins.elem proto routeEnums.proto);
          msg = "proto must be http, tcp or udp";
        }
        {
          bad = exposure != "local" && auth == null;
          msg = "auth is required when exposure != \"local\" (native-oidc, native, oauth2-proxy or none)";
        }
        {
          bad = isPublic && auth == "none" && !(r.publicWithoutAuth or false);
          msg = "exposure = \"public\" with auth = \"none\" needs publicWithoutAuth = true";
        }
        {
          bad = (r ? icon) && !(builtins.isString r.icon);
          msg = "icon must be a string (URL or icon name)";
        }
        {
          bad = (r ? group) && !(builtins.isString r.group && r.group != "");
          msg = "group must be a non-empty string";
        }
        {
          bad = !(builtins.isList (r.allow or [ ])) || !(builtins.all builtins.isString (r.allow or [ ]));
          msg = "allow must be a list of host names";
        }
        {
          # The serving host's nginx renders allow as per-host `allow
          # <overlayIp>; # allow: <host>` lines plus `deny all;` instead of
          # the tailnet ACL include (cli/routes.go routesVhost), and
          # webSourcesByHost feeds the same overlay IPs to the host firewall.
          bad = isHttp && (r.allow or [ ]) != [ ] && exposure != "tailnet";
          msg = "allow on http routes is only implemented for exposure = \"tailnet\"";
        }
        {
          bad = isHttp && (builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" name == null);
          msg = "name ${builtins.toJSON name} must be a single DNS label";
        }
        {
          bad = (r ? groups || r ? bypass) && auth != "oauth2-proxy";
          msg = "groups/bypass only apply to auth = \"oauth2-proxy\"";
        }
        {
          bad =
            !(builtins.isList (r.groups or [ ]))
            || !(builtins.all (g: builtins.isString g && builtins.match "[A-Za-z0-9_.-]+" g != null) (
              r.groups or [ ]
            ));
          msg = "groups must be a list of zitadel role names ([A-Za-z0-9_.-])";
        }
        {
          bad =
            !(builtins.isList (r.bypass or [ ]))
            || !(builtins.all (p: builtins.isString p && builtins.match "/[A-Za-z0-9_./-]*" p != null) (
              r.bypass or [ ]
            ));
          msg = "bypass must be a list of path prefixes like \"/api/\"";
        }
      ];
      firstBad = builtins.filter (c: c.bad) checks;
    in
    if firstBad != [ ] then
      fail (builtins.head firstBad).msg
    else
      {
        inherit
          proto
          exposure
          auth
          via
          ;
        port = r.port;
        allow = r.allow or [ ];
        health = r.health or null;
        # informational: start-page icon for fleet-edge (URL or CDN icon name)
        icon = r.icon or null;
        # informational: start-page category for fleet-edge
        group = r.group or null;
        publicWithoutAuth = r.publicWithoutAuth or false;
      }
      // (
        if isHttp then
          {
            inherit name fqdn;
            url = "https://${fqdn}";
            websockets = r.websockets or true;
            maxBody = r.maxBody or "100m";
            buffering = r.buffering or true;
            timeouts = r.timeouts or "60s";
            requestBuffering = r.requestBuffering or true;
            forwardedProto = r.forwardedProto or "https";
            extraConfig = r.extraConfig or "";
            # oauth2-proxy: zitadel roles (any of) and unauthenticated path prefixes
            groups = r.groups or [ ];
            bypass = r.bypass or [ ];
          }
        else
          {
            name = null;
            fqdn = null;
            url = null;
          }
      );

  normalizeRoutes =
    svc:
    let
      raw = svc.routes or { };
      routes = builtins.mapAttrs (normalizeRoute svc.name) raw;
      fqdns = builtins.filter (f: f != null) (map (r: r.fqdn) (builtins.attrValues routes));
      dup = builtins.filter (f: builtins.length (builtins.filter (x: x == f) fqdns) > 1) fqdns;
    in
    if !(builtins.isAttrs raw) then
      throw "${svc.name}: routes must be an attrset"
    else if raw != { } && (svc.nginx or null) != null then
      throw "${svc.name}: set either routes or nginx, not both (nginx is the escape hatch for unconverted services)"
    else if dup != [ ] then
      throw "${svc.name}: two routes use the name ${builtins.head dup}"
    else
      routes;

  # Private container networking (ROUTING-PLAN §8 step 5). Opt-in per
  # service: net = { private = true; index = N; }. For kind = "nixos" the
  # guest is 10.233.<N>.2 on every host (index is fleet-wide unique within
  # the kind, checked by checkNetIndexes); the host side of every veth is
  # netHostAddress. The host only lets a guest reach the internet and its
  # DNS. Exceptions:
  #   uses   = [ "svc.route" ]   another service's route, both ways: this
  #            guest may reach it (egress allow, cli/routes.go
  #            netExceptions: the guest IP when both are private on one
  #            host, else the target host's overlay IP on tcp 443, its
  #            nginx), and the target admits this caller on 80/443 in its
  #            own ports file, from the hosts discovery puts the caller on
  #            (cli/routes.go srcPortLines) -- not from its `host` field.
  #            That file is refreshed after a deploy, move or destroy.
  #   egress = [ "10.12.14.181:9010/tcp" ]   a fixed LAN/tailnet endpoint.
  # For kind = "podman", `index` instead picks a static address on the
  # shared fleet-noinet bridge (10.89.250.<N>, a separate fleet-wide-unique
  # space): podman doesn't have a per-service veth, so the static --ip
  # stands in for one. uses/egress aren't implemented for podman yet.
  netHostAddress = "10.233.0.1";
  normalizeNet =
    s:
    let
      n = {
        private = false;
        index = null;
        uses = [ ];
        egress = [ ];
      }
      // (s.net or { });
      fail = msg: throw "${s.name}: net: ${msg}";
      unknown = builtins.filter (
        k:
        !(builtins.elem k [
          "private"
          "index"
          "uses"
          "egress"
        ])
      ) (builtins.attrNames n);
      badUse = builtins.filter (u: builtins.match "[a-z0-9-]+\\.[a-z0-9-]+" u == null) n.uses;
      badEgress = builtins.filter (
        e: builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+/(tcp|udp)" e == null
      ) n.egress;
    in
    if unknown != [ ] then
      fail "unknown key(s) ${builtins.concatStringsSep ", " unknown}"
    else if !n.private then
      (
        if n.uses != [ ] || n.egress != [ ] then
          fail "uses/egress only apply with private = true"
        else
          {
            private = false;
            index = null;
            ip = null;
            uses = [ ];
            egress = [ ];
          }
      )
    else if s.kind == "podman" then
      (
        if !(builtins.isInt n.index) || n.index < 1 || n.index > 154 then
          fail "index must be an integer 1-154 (fleet-wide unique within kind, never reuse one)"
        else if n.uses != [ ] || n.egress != [ ] then
          fail "uses/egress are not implemented for kind = \"podman\""
        else
          {
            private = true;
            inherit (n) index uses egress;
            # Static IP on the shared fleet-noinet bridge (10.89.250.0/24,
            # containers/lib.nix mkPodmanService, host-module.nix).
            # 10.89.250.1 is the bridge/gateway (podman network inspect
            # fleet-noinet); podman's host-local IPAM hands out .2 upward to
            # any container on the network without a static --ip (e.g. a
            # future non-private podman service with internet = false).
            # Offsetting by 100 (.101-.254) keeps every static IP clear of
            # both the gateway and that dynamic low range. Index is a
            # separate fleet-wide-unique space from the nixos net.index
            # (10.233.x); checked by checkNetIndexes per kind.
            ip = "10.89.250.${toString (100 + n.index)}";
          }
      )
    else if !(builtins.isInt n.index) || n.index < 1 || n.index > 254 then
      fail "index must be an integer 1-254 (fleet-wide unique, never reuse one)"
    else if builtins.stringLength s.name > 11 then
      fail "service name must be <= 11 characters (veth ve-<name>)"
    else if s.tcpPorts != [ ] || s.udpPorts != [ ] then
      fail "tcpPorts/udpPorts don't reach a private guest; declare tcp/udp routes instead (they get DNAT)"
    else if s.nginx != null then
      fail "nginx strings proxy to 127.0.0.1; convert to routes first"
    else if badUse != [ ] then
      fail "uses entry ${builtins.toJSON (builtins.head badUse)} is not \"<service>.<route>\""
    else if badEgress != [ ] then
      fail "egress entry ${builtins.toJSON (builtins.head badEgress)} is not \"<ipv4>:<port>/<tcp|udp>\""
    else
      {
        private = true;
        inherit (n) index uses egress;
        ip = "10.233.${toString n.index}.2";
      };

  # Throws if two services of the same kind share a net.index (nixos and
  # podman indices are separate address spaces: 10.233.<i>.2 vs
  # 10.89.250.<i>, so a collision across kinds is harmless).
  checkNetIndexes =
    services:
    let
      checkKind =
        kind:
        let
          priv = builtins.filter (s: s.net.private && s.kind == kind) services;
          idx = map (s: s.net.index) priv;
          dup = builtins.filter (i: builtins.length (builtins.filter (x: x == i) idx) > 1) idx;
        in
        if dup != [ ] then
          throw "net.index ${toString (builtins.head dup)} (kind ${kind}) is used by ${
            builtins.concatStringsSep " and " (
              map (s: s.name) (builtins.filter (s: s.net.index == builtins.head dup) priv)
            )
          }"
        else
          true;
    in
    assert checkKind "nixos";
    assert checkKind "podman";
    services;

  # Defaults so service.nix files can stay short.
  normalize =
    service:
    let
      s = {
        kind = "nixos";
        # DEPRECATED build-time seed (PLACEMENT-PLAN.md §4/§9). Placement is
        # runtime now: the fleet-edge registry is the source of truth and `cnt`
        # resolves a service's host from it. `host` survives only so the
        # remaining Nix builders below can keep deriving from it until phase 5
        # deletes the field and every reader in one cutover:
        #   edgeRoutes, edgeVirtualHosts, routeNamesByHost/tlsNamesByHost,
        #   webSourcesByHost, dnsRecords,
        #   host-module.nix's httpExposureByHost, containers/flake.nix's
        #   containerHosts comment.
        # Do not add a reader, and do not add a `host` to a new service.nix:
        # record the destination with `cnt place <svc> --set <host>` instead.
        host = null;
        persist = { };
        tcpPorts = [ ];
        requires = [ ];
        udpPorts = [ ];
        nginx = null;
        routes = { };
        # false: podman services join the fleet-noinet network (host-module.nix);
        # nixos services need net.private and get their veth in the host's
        # fleet-net @noinet set. Published ports/routes still work; the
        # container cannot open any connection (podman: not even DNS).
        internet = true;
        description = "";
      }
      // service;
    in
    s
    // {
      routes = normalizeRoutes s;
      net = normalizeNet s;
    };

  # The edge listener port on service hosts (ROUTING-PLAN §2.3). Keep in
  # sync with cli/routes.go edgePort.
  edgePort = 8443;

  # oauth2-proxy hygiene for any vhost under .joshuabell.xyz that proxies to
  # an app (ROUTING-PLAN §4). Same files cli/routes.go embeds, so there is one
  # copy. cookieStrip goes in the server block (sets $fleet_cookie);
  # identityClear in each app-facing proxy location (never in oauth2-proxy's
  # own /oauth2/ locations, which need the cookie).
  nginxSnippets = {
    cookieStrip = builtins.readFile ../flakes/fleet-agent/internal/containers/nginx/oauth2-cookie-strip.conf;
    identityClear = builtins.readFile ../flakes/fleet-agent/internal/containers/nginx/oauth2-identity-clear.conf;
  };

  allServices =
    dir:
    let
      entries = builtins.readDir dir;
      dirs = builtins.filter (
        d: entries.${d} == "directory" && builtins.pathExists (dir + "/${d}/service.nix")
      ) (builtins.attrNames entries);
    in
    checkNetIndexes (map (d: normalize (import (dir + "/${d}/service.nix"))) dirs);

  # Public http routes reached through the edge (o002), each with `service`.
  # DEPRECATED reader of the `host` seed: a service with `host = null` is
  # skipped because build time cannot know where it runs. The registry does;
  # phase 5 deletes this function and o002's vhosts come from the reconciler.
  edgeRoutes =
    dir:
    builtins.filter
      (
        r:
        r.proto == "http" && r.exposure == "public" && builtins.elem "edge" r.via && r.service.host != null
      )
      (
        builtins.concatMap (s: map (r: r // { service = s; }) (builtins.attrValues s.routes)) (
          allServices dir
        )
      );

  # Tailnet peers a host's own http vhosts must not serve: o002 (the public
  # edge, which reaches them through its edge listener instead) and the
  # low-trust nodes (hosts/fleet.nix trust = "low"). ROUTING-PLAN 8.2.
  # Container hosts do not need this: webSourcesByHost lists exactly who may
  # reach them. h005 does, because its vhosts (fleet-edge dashboard,
  # oauth2-proxy sso-proxy) are hand-written and sso-proxy must stay
  # reachable from devices that are not in fleet.nix at all (phones).
  tailnetExcludedOverlayIps =
    hosts:
    builtins.filter (ip: ip != null) (
      map (name: hosts.${name}.overlayIp or null) (
        builtins.filter (name: name == "o002" || (hosts.${name}.trust or null) == "low") (
          builtins.attrNames hosts
        )
      )
    );

  # An IPv4/IPv6 literal or CIDR block, as used in nft set elements and
  # allow lists. Validated at eval time so a typo fails the build instead of
  # producing a ruleset nft rejects at boot.
  validWebSource =
    s:
    builtins.match "^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$" s != null
    || builtins.match "^[0-9a-f]{0,4}(:[0-9a-f]{0,4}){2,7}(/[0-9]{1,3})?$" s != null;

  # Split web-admission sources into the v4/v6 lists the host firewall rules
  # use (`ip saddr` vs `ip6 saddr`). Throws on a malformed entry.
  #   sources  list of addresses/CIDRs
  #   family   "v4" or "v6"
  webSourcesIps =
    { sources, family }:
    let
      bad = builtins.filter (s: !validWebSource s) sources;
      isV4 = s: builtins.match "^[^:]*$" s != null;
    in
    if bad != [ ] then
      throw "webSourcesIps: ${builtins.toJSON (builtins.head bad)} is not an IPv4/IPv6 address or CIDR"
    else if family != "v4" && family != "v6" then
      throw "webSourcesIps: family must be \"v4\" or \"v6\""
    else
      builtins.filter (s: isV4 s == (family == "v4")) sources;

  # The build-time half of the 80/443 admission (ROUTING-PLAN 8.2) for this
  # host's own internal nginx: literal `ip saddr` rules from the routes the
  # inventory declares for it, instead of a blanket
  # `ip saddr 100.64.0.0/10 accept`. The runtime half (`@src`/`@src6`/
  # `@src_lan`) is written per service by `containers deploy` from that
  # service's own routes, so this map only covers what is declared here at
  # build time. nginx still enforces the per-vhost exposure ACL; both are only
  # the TCP admission.
  #   dir    the containers directory
  #   extra  per-host additions for hand vhosts outside the inventory
  #          (h001's arr media-health aliases)
  #   hosts  fleet.nix hosts (overlayIp)
  # Returns { <host> = { tailnet = [ addr-or-cidr ]; lan = bool; }; },
  # sorted and deduped, omitting hosts with nothing to admit:
  #   tailnet  `100.64.0.0/10` for a route without `allow`, else the
  #            overlay IP of every host it names
  #   lan      the host also serves LAN clients directly on 80/443 (a
  #            lan/public route that is not `via = [ "router" ]`).
  # Not covered: a `via = [ "router" ]` public route's LAN clients, which
  # h005 DNATs and which arrive with the WAN source (see ROUTING-PLAN 8.2).
  webSourcesByHost =
    {
      dir,
      extra ? { },
      hosts ? fleetHosts.hosts,
    }:
    let
      routes = builtins.filter (r: r.proto == "http" && r.exposure != "local") (
        builtins.concatMap (s: map (r: r // { inherit (s) host; }) (builtins.attrValues s.routes)) (
          builtins.filter (s: s.host != null) (allServices dir)
        )
      );
      allowIps =
        r:
        map (
          n:
          hosts.${n}.overlayIp
            or (throw "webSourcesByHost: ${r.fqdn}: allow names ${n}, which has no overlayIp in fleet.nix")
        ) r.allow;
      # No allow list means every tailnet node may reach nginx (it still
      # enforces the per-vhost ACL); an allow list narrows admission to it.
      sourcesOf = r: if r.allow == [ ] then [ "100.64.0.0/10" ] else allowIps r;
      computed = builtins.mapAttrs (_: rs: {
        tailnet = builtins.concatMap sourcesOf rs;
        lan = builtins.any (
          r: (r.exposure == "lan" || r.exposure == "public") && !(builtins.elem "router" r.via)
        ) rs;
      }) (builtins.groupBy (r: r.host) routes);
      merged =
        builtins.mapAttrs (h: v: {
          tailnet = v.tailnet ++ (extra.${h}.tailnet or [ ]);
          lan = v.lan || (extra.${h}.lan or false);
        }) computed
        // builtins.mapAttrs (_: e: {
          tailnet = e.tailnet or [ ];
          lan = e.lan or false;
        }) (builtins.removeAttrs extra (builtins.attrNames computed));
      out = builtins.mapAttrs (_: v: {
        tailnet = builtins.sort builtins.lessThan (
          builtins.attrNames (
            builtins.listToAttrs (
              map (s: {
                name = s;
                value = null;
              }) v.tailnet
            )
          )
        );
        inherit (v) lan;
      }) merged;
    in
    builtins.removeAttrs out (
      builtins.filter (h: out.${h}.tailnet == [ ] && !out.${h}.lan) (builtins.attrNames out)
    );
in
{
  inherit
    dataRoot
    lanSubnet
    persistList
    normalize
    normalizeRoute
    edgePort
    edgeRoutes
    nginxSnippets
    netHostAddress
    checkNetIndexes
    allServices
    tailnetExcludedOverlayIps
    validWebSource
    webSourcesIps
    webSourcesByHost
    ;

  # services.nginx.virtualHosts for the public edge (o002), generated from
  # every public `via = edge` http route (ROUTING-PLAN §2.3, §8 step 3).
  # Each proxies over the tailnet to the service host's edge listener
  # (<overlayIp>:edgePort), which admits only the edge's overlay IP and
  # serves only routes that are public there right now.
  #   dir    the containers directory (inputs.containers.outPath or ./.)
  #   hosts  fleet.nix hosts (overlay IPs)
  #   tls    TLS attrs merged into every vhost; default per-name http-01
  #          (o002 holds no bunny key, so no wildcard there yet; §8 step 4).
  edgeVirtualHosts =
    {
      dir,
      hosts,
      tls ? {
        enableACME = true;
        forceSSL = true;
      },
    }:
    builtins.listToAttrs (
      map (
        r:
        let
          h = r.service.host;
          ip =
            hosts.${h}.overlayIp
              or (throw "edgeVirtualHosts: ${r.fqdn}: host ${h} has no overlayIp in fleet.nix");
        in
        {
          name = r.fqdn;
          value = tls // {
            locations."/" = {
              proxyPass = "http://${ip}:${toString edgePort}";
              proxyWebsockets = r.websockets;
              extraConfig = ''
                # generated: containers ${r.service.name} (lib.nix edgeVirtualHosts)
                client_max_body_size ${r.maxBody};
                proxy_buffering ${if r.buffering then "on" else "off"};
                proxy_request_buffering ${if r.requestBuffering then "on" else "off"};
                proxy_read_timeout ${r.timeouts};
                proxy_send_timeout ${r.timeouts};
              '';
            };
          };
        }
      ) (edgeRoutes dir)
    );

  # TLS names per serving host: every exposed (non-local) http route's fqdn,
  # grouped by its service's host, each list sorted. Each host's own nginx
  # terminates TLS for these names. h005's cert push
  # (hosts/h005/wildcard-cert.nix) derives its targets and the per-host
  # SANs of low-trust hosts from this. Services without a host are skipped.
  routeNamesByHost =
    dir:
    let
      routes = builtins.filter (r: r.proto == "http" && r.exposure != "local") (
        builtins.concatMap (s: map (r: r // { inherit (s) host; }) (builtins.attrValues s.routes)) (
          builtins.filter (s: s.host != null) (allServices dir)
        )
      );
    in
    builtins.mapAttrs (_: rs: builtins.sort builtins.lessThan (map (r: r.fqdn) rs)) (
      builtins.groupBy (r: r.host) routes
    );

  # ROUTING-PLAN §8 step 2: explicit per-host firewall, generated from the
  # inventory instead of hand-written global allows ("every host trusts
  # tailscale0" is gone; this is what replaces the blanket 22/80/443).
  #   hosts     fleet.nix hosts (overlayIp, trust)
  #   exclude   host names to leave out even if high trust (o002: edge
  #             traffic must never satisfy a tailnet http allow)
  # v6 is not generated (no host in fleet.nix has an overlayIp6 yet); a
  # host that gains one needs a manual addition, same as nginx.edge.peers.
  firewallHighTrustIps =
    {
      hosts,
      exclude ? [ ],
    }:
    builtins.filter (ip: ip != null) (
      map (n: hosts.${n}.overlayIp or null) (
        builtins.filter (n: (hosts.${n}.trust or null) == "high" && !(builtins.elem n exclude)) (
          builtins.attrNames hosts
        )
      )
    );

  # LAN SSH fallback must not admit low-trust devices. Use a separate base
  # chain before nixos-fw: extraInputRules drops run after its accepts.
  # Keep all low-trust LAN IPs, including the destination host's own IP.
  lowTrustLanSshTable =
    {
      hosts,
      host,
      lib,
    }:
    let
      ips = builtins.filter (ip: ip != null) (
        map (h: if (h.trust or null) == "low" then h.lanIp or null else null) (builtins.attrValues hosts)
      );
    in
    lib.mkIf (ips != [ ]) {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority -10; policy accept;
          ip saddr { ${builtins.concatStringsSep ", " ips} } tcp dport 22 counter drop comment "M3: low-trust LAN devices must not reach ${host} SSH"
        }
      '';
    };

  # Lockout guard (ROUTING-PLAN §8 step 2): every host's generated ssh
  # allow-list must be non-empty and must contain lio's overlay IP, or a
  # fleet.nix typo / scoping bug silently locks out ssh from lio. Build a
  # NixOS `assertions` entry for the module that computes `ips` via
  # `firewallHighTrustIps`; fails the eval instead of the deploy.
  #   ips   the computed high-trust ssh allow-list for this host
  #   hosts fleet.nix hosts (for lio's overlayIp)
  #   host  this host's name, for the assertion message
  sshGuardAssertion =
    {
      ips,
      hosts,
      host,
    }:
    {
      assertion = ips != [ ] && builtins.elem (hosts.lio.overlayIp or null) ips;
      message = "ROUTING-PLAN §8 step 2: ${host}'s generated ssh allow-list is empty or excludes lio's overlay IP (${
        toString (hosts.lio.overlayIp or null)
      }) -- this would lock out ssh from lio; computed list: [ ${builtins.concatStringsSep ", " ips} ]";
    };

  # DNS records for every exposed route, from service.nix
  # (ROUTING-PLAN §2.1, §8 step 4). Build-time: h005 (tailnet + LAN
  # dnsmasq) and the bunny reconciler read this, so a record changes when
  # h005 is rebuilt from a tree with the new service.nix.
  #   dir    the containers directory
  #   hosts  fleet.nix hosts (overlayIp, lanIp)
  # Returns lists of { fqdn; source; ... }, sorted by fqdn:
  #   tailnet  every non-local route -> its host's overlay IP
  #   lan      lan + public routes -> its host's LAN IP (hosts without a
  #            lanIp get no LAN record: LAN clients fall through to public)
  #   public   public routes -> CNAME o002 (via edge) or home (via router)
  # Route names and public membership are independent of placement.
  dnsRecords =
    { dir, hosts }:
    let
      routes = builtins.filter (r: r.exposure != "local" && r.fqdn != null) (
        builtins.concatMap (
          s:
          map (
            n:
            s.routes.${n}
            // {
              source = "${s.name}.${n}";
              service = s.name;
              host = s.host;
            }
          ) (builtins.attrNames s.routes)
        ) (allServices dir)
      );
      hostIp =
        r: field:
        (hosts.${r.host} or (throw "dnsRecords: ${r.source}: host ${r.host} is not in fleet.nix")).${field}
          or null;
      overlayIp =
        r:
        let
          ip = hostIp r "overlayIp";
        in
        if ip == null then throw "dnsRecords: ${r.source}: host ${r.host} has no overlayIp" else ip;
      sortByName = builtins.sort (a: b: a.fqdn < b.fqdn);
      dups =
        l:
        let
          names = map (x: x.fqdn) l;
        in
        builtins.filter (n: builtins.length (builtins.filter (x: x == n) names) > 1) names;
      checked =
        l:
        if dups l != [ ] then
          throw "dnsRecords: ${builtins.head (dups l)} is declared twice"
        else
          sortByName l;
    in
    {
      names = checked (map (r: { inherit (r) fqdn source service; }) routes);
      tailnet = checked (
        map (r: {
          inherit (r) fqdn source;
          ip = overlayIp r;
        }) (builtins.filter (r: r.host != null) routes)
      );
      lan = checked (
        map
          (r: {
            inherit (r) fqdn source;
            ip = hostIp r "lanIp";
          })
          (
            builtins.filter (
              r: r.host != null && (r.exposure == "lan" || r.exposure == "public") && hostIp r "lanIp" != null
            ) routes
          )
      );
      public = checked (
        map (r: {
          inherit (r) fqdn source service;
          type = "CNAME";
          target = "${if builtins.elem "edge" r.via then "o002" else "home"}.${domain}";
        }) (builtins.filter (r: r.exposure == "public") routes)
      );
    };

  # Placement-free admission list for the edge's runtime TCP stream receiver.
  edgeStreamPorts = dir:
    builtins.sort builtins.lessThan (builtins.attrValues (builtins.listToAttrs (
      builtins.concatMap (s: map (r: { name = toString r.port; value = r.port; })
        (builtins.filter (r: r.exposure == "public" && r.proto == "tcp" && builtins.elem "edge" r.via)
          (builtins.attrValues s.routes))) (allServices dir)
    )));

  # The extra-container `config` for a nixos-kind service. Pass it to
  # extra-container.lib.buildContainers { config = ...; }.
  #
  #   privateUsers = "pick"  nspawn picks a free 64k UID range on each start.
  #                          Every bind (including /nix) is idmapped, so the
  #                          filesystem behind /srv/containers must support
  #                          idmapped mounts (ext4, btrfs, xfs, tmpfs,
  #                          bcachefs on recent kernels; run `containers check-idmap`).
  #   privateUsers = "no"    no user namespace: container uids are host uids.
  #                          Needed when the container writes to NFS (idmapped
  #                          mounts don't work there and the NAS checks raw
  #                          uids). Container root is host root; pin uids.
  #   privateUsers = "identity"  user namespace mapping uids 0..65535 1:1 to
  #                          the host. Files/NFS behave as with "no" (plain
  #                          binds, pin uids), but nspawn capabilities (even
  #                          CAP_SYS_ADMIN) only count inside the container's
  #                          own user namespace, never in the host's.
  #   guestNixpkgs           evaluate the guest with another nixpkgs (e.g.
  #                          26.05) while extra-container's host-side eval
  #                          stays on the flake's nixpkgs (25.11, issue #40).
  #   binds                  extra host paths, not part of persist/backups:
  #                          [ { host; container ? host; readOnly ? false; } ]
  #   devices                device nodes to pass through, e.g. [ "/dev/dri" ]
  #                          (bound and allowed rw in the container's cgroup)
  #   capabilities           extra nspawn capabilities, e.g. [ "CAP_NET_ADMIN" ]
  #   dropCapabilities       nspawn capabilities to drop from the default set,
  #                          e.g. [ "CAP_NET_RAW" ]
  mkNixosContainer =
    {
      service,
      config,
      specialArgs ? { },
      privateUsers ? "pick",
      privateNetwork ? false,
      guestNixpkgs ? null,
      binds ? [ ],
      devices ? [ ],
      capabilities ? [ ],
      dropCapabilities ? [ ],
      extraContainerConfig ? { },
    }:
    let
      svc =
        let
          s = normalize service;
        in
        if s.internet || s.net.private then
          s
        else
          throw "${s.name}: internet = false needs net.private for kind = \"nixos\"";
      # net.private (service.nix) is the supported switch; the legacy
      # privateNetwork argument gives a veth without addresses (unused).
      private = svc.net.private || privateNetwork;
      # Private guests admit local routes too: only net.uses guests on this
      # host can reach them (the host isolates every other source).
      exposed = builtins.filter (r: r.exposure != "local" || svc.net.private) (
        builtins.attrValues svc.routes
      );
      portsOf = proto: map (r: r.port) (builtins.filter (r: r.proto == proto) exposed);
      # "no" and "identity" see host uids 1:1: plain binds (works on NFS,
      # which has no FS_ALLOW_IDMAP).
      idmap = if privateUsers == "no" || privateUsers == "identity" then "" else ":idmap";
      bindFlag =
        b: "--bind${if b.readOnly or false then "-ro" else ""}=${b.host}:${b.container or b.host}${idmap}";
      # Passed to the guest (specialArgs.fleetNet): what to bind, where the host is.
      fleetNet = {
        inherit (svc.net) private ip;
        bindAddress = if svc.net.private then "0.0.0.0" else "127.0.0.1";
        hostAddress = if svc.net.private then netHostAddress else "127.0.0.1";
      };
    in
    { pkgs, lib, ... }:
    {
      containers.${svc.name} = {
        ephemeral = true;
        autoStart = true;
        inherit privateUsers;
        privateNetwork = private;
        specialArgs = specialArgs // {
          inherit fleetNet;
        };
        extraFlags =
          map (b: "--bind=${b.host}:${b.container}${idmap}") (persistList svc)
          ++ map bindFlag binds
          ++ map (d: "--bind=${d}") devices
          ++ map (c: "--capability=${c}") capabilities
          ++ map (c: "--drop-capability=${c}") dropCapabilities;
        allowedDevices = map (d: {
          node = if d == "/dev/dri" then "char-drm" else d;
          modifier = "rw";
        }) devices;
        config =
          { lib, ... }:
          {
            imports = [
              config
              (
                if svc.net.private then
                  {
                    # Private network (ROUTING-PLAN §8 step 5): the guest firewall
                    # admits only the exposed route ports (host nginx or DNAT).
                    # DNS goes to the host's resolved stub on the veth, so the
                    # guest gets the same split-horizon answers as the host.
                    networking.useHostResolvConf = lib.mkForce false;
                    networking.nameservers = [ netHostAddress ];
                    networking.firewall.allowedTCPPorts = portsOf "http" ++ portsOf "tcp";
                    networking.firewall.allowedUDPPorts = portsOf "udp";
                  }
                else
                  { }
              )
            ];
            # With the host network the guest has no CAP_NET_ADMIN on the host
            # namespace (privateUsers), so its firewall can't load. The host
            # firewall is the one that counts; ports are opened by `containers`.
            networking.firewall.enable = lib.mkIf (!private) (lib.mkForce false);
          };
      }
      // (
        if svc.net.private then
          {
            hostAddress = netHostAddress;
            localAddress = svc.net.ip;
          }
        else
          { }
      )
      // (if guestNixpkgs == null then { } else { nixpkgs = guestNixpkgs; })
      // extraContainerConfig;
      # Don't start (and stop) when a persist/bind source's mount is missing,
      # e.g. an unmounted /drives/wd10 would otherwise be bound as an empty dir.
      systemd.services."container@${svc.name}" = {
        unitConfig.RequiresMountsFor = map (b: b.host) (persistList svc) ++ map (b: b.host) binds;
        # net.private: host-module.nix fleet-veth@ configures ve-<name> as soon
        # as it appears (before the guest is READY). The stock postStart
        # (ip addr/route add, after READY) would then fail on EEXIST, so do
        # the same with replace: still sets it up on hosts without the hook.
        serviceConfig = lib.mkIf svc.net.private {
          ExecStartPost = lib.mkForce [
            (pkgs.writeShellScript "fleet-veth-poststart-${svc.name}" ''
              set -eu
              ifc=ve-${svc.name}
              ${pkgs.iproute2}/bin/ip link set dev "$ifc" up
              ${pkgs.iproute2}/bin/ip addr replace ${netHostAddress} dev "$ifc"
              ${pkgs.iproute2}/bin/ip route replace ${svc.net.ip} dev "$ifc"
            '')
          ];
        };
      };
    };

  # A deployable podman service. Produces a store path with:
  #   etc/systemd/system/fleet-<name>.service
  #   bin/fleet-install    links the unit into /etc/systemd-mutable/system and (re)starts it
  #   bin/fleet-uninstall  stops the unit and removes the link (data is kept)
  #
  # `podman` attrs:
  #   image       required, e.g. "docker.io/traefik/whoami:v1.10"
  #   ports       list of "hostPort:containerPort" strings (published on 127.0.0.1
  #               unless an address is given, e.g. "0.0.0.0:25565:25565")
  #   environment attrset of env vars
  #   extraArgs   list of extra `podman run` args
  #   cmd         list, the container command
  mkPodmanService =
    {
      pkgs,
      service,
    }:
    let
      svc = normalize service;
      p = svc.podman;
      unitName = "fleet-${svc.name}.service";
      lib = pkgs.lib;
      # Private (net.private, podman): no publish needed at all. nginx
      # (routes.go backendAddr) proxies straight to the bridge IP:port,
      # which podman routes without a --publish, same as a nixos guest's
      # veth. A bare "port:port" entry (the old 127.0.0.1-default) is
      # dropped; an explicit host address (e.g. "0.0.0.0:X:Y", for a port
      # meant to stay reachable on every interface alongside the private
      # IP) still publishes as written.
      publish = builtins.filter (x: x != null) (
        map (
          port:
          let
            parts = lib.splitString ":" port;
          in
          if builtins.length parts == 2 then
            (if svc.net.private then null else "--publish=127.0.0.1:${port}")
          else
            "--publish=${port}"
        ) (p.ports or [ ])
      );
      volumes = map (b: "--volume=${b.host}:${b.container}:idmap") (persistList svc);
      envs = lib.mapAttrsToList (k: v: "--env=${k}=${toString v}") (p.environment or { });
      runArgs = [
        "--rm"
        "--name=${svc.name}"
        "--replace"
        "--userns=auto"
        "--sdnotify=conmon"
        "--log-driver=journald"
      ]
      ++ lib.optional (!svc.internet || svc.net.private) "--network=fleet-noinet"
      ++ lib.optional svc.net.private "--ip=${svc.net.ip}"
      ++ publish
      ++ volumes
      ++ envs
      ++ (p.extraArgs or [ ])
      ++ [ p.image ]
      ++ (p.cmd or [ ]);
      # The host's fleet-noinet nft table (host-module.nix, part of the
      # declarative ruleset, so firewall reloads re-create it) drops every new
      # connection from this network. Start fails if the table is missing.
      # Not no_default_route: it also breaks replies to clients on other
      # subnets (e.g. a port published on the tailnet IP).
      noInetSetup = pkgs.writeShellScript "fleet-noinet-setup" ''
        set -eu
        P=/run/current-system/sw/bin/podman
        /run/current-system/sw/bin/nft list table inet fleet-noinet >/dev/null
        if $P network inspect --format '{{.Options}}' fleet-noinet 2>/dev/null | grep -q 'no_default_route'; then
          $P network rm -f fleet-noinet
        fi
        $P network exists fleet-noinet \
          || $P network create --interface-name=fleet-noinet --subnet=10.89.250.0/24 fleet-noinet
      '';
      noInetPre = ''
        ExecStartPre=${noInetSetup}
      '';
      unit = pkgs.writeText unitName ''
                [Unit]
                Description=containers podman service ${svc.name}
                Wants=network-online.target
                After=network-online.target
                ${lib.concatMapStrings (b: "RequiresMountsFor=${b.host}\n") (persistList svc)}
                [Service]
                Type=notify
                NotifyAccess=all
                Restart=on-failure
                TimeoutStartSec=900
                TimeoutStopSec=120
                Environment=PATH=/run/wrappers/bin:/run/current-system/sw/bin
        ${
          lib.optionalString (!svc.internet) noInetPre
        }        # Host podman, not pkgs.podman: the runtime must match the host kernel,
                # CDI specs and nvidia hook (nixos-25.11 crun 1.24 fails NVIDIA CDI mounts).
                ExecStart=/run/current-system/sw/bin/podman run ${lib.escapeShellArgs runArgs}
                ExecStop=/run/current-system/sw/bin/podman stop --ignore --time=60 ${svc.name}

                [Install]
                WantedBy=multi-user.target
      '';
      mutable = "/etc/systemd-mutable/system";
      install = pkgs.writeShellScript "fleet-install" ''
        set -euo pipefail
        self=$(dirname "$(dirname "$(readlink -f "$0")")")
        mkdir -p ${mutable}/multi-user.target.wants /nix/var/nix/gcroots/fleet-containers
        ln -sfn "$self" /nix/var/nix/gcroots/fleet-containers/${svc.name}
        old=$(readlink -f ${mutable}/${unitName} 2>/dev/null || true)
        ln -sfn "$self/etc/systemd/system/${unitName}" ${mutable}/${unitName}
        ln -sfn ../${unitName} ${mutable}/multi-user.target.wants/${unitName}
        systemctl daemon-reload
        if [ "$old" != "$(readlink -f ${mutable}/${unitName})" ] || ! systemctl is-active -q ${unitName}; then
          systemctl restart ${unitName}
        fi
      '';
      uninstall = pkgs.writeShellScript "fleet-uninstall" ''
        set -euo pipefail
        systemctl stop ${unitName} || true
        rm -f ${mutable}/${unitName} ${mutable}/multi-user.target.wants/${unitName} /nix/var/nix/gcroots/fleet-containers/${svc.name}
        systemctl daemon-reload
      '';
    in
    pkgs.runCommand "fleet-${svc.name}" { } ''
      install -D -m644 ${unit} $out/etc/systemd/system/${unitName}
      install -D -m755 ${install} $out/bin/fleet-install
      install -D -m755 ${uninstall} $out/bin/fleet-uninstall
    '';
}
