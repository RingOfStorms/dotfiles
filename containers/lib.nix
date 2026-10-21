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
    zone = [
      "main"
      "private"
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
    "zone"
    "websockets"
    "maxBody"
    "buffering"
    "timeouts"
    "requestBuffering"
    "forwardedProto"
    "extraConfig"
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
      zone = oneOf "zone" (r.zone or "main");
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
      fqdn = if zone == "private" then "${name}.ts.${domain}" else "${name}.${domain}";
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
          bad = isPublic && zone == "private";
          msg = "zone = \"private\" names can't be public";
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
          bad = isHttp && (builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" name == null);
          msg = "name ${builtins.toJSON name} must be a single DNS label";
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
            inherit name zone fqdn;
            url = "https://${fqdn}";
            websockets = r.websockets or true;
            maxBody = r.maxBody or "100m";
            buffering = r.buffering or true;
            timeouts = r.timeouts or "60s";
            requestBuffering = r.requestBuffering or true;
            forwardedProto = r.forwardedProto or "https";
            extraConfig = r.extraConfig or "";
          }
        else
          {
            name = null;
            zone = null;
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

  # Defaults so service.nix files can stay short.
  normalize =
    service:
    let
      s = {
        kind = "nixos";
        host = null;
        persist = { };
        tcpPorts = [ ];
        requires = [ ];
        udpPorts = [ ];
        nginx = null;
        routes = { };
        # false: podman services join the fleet-noinet network (host-module.nix).
        # Published ports still work; the container cannot open any connection
        # (no internet, LAN, host or DNS). Not implemented for kind = "nixos".
        internet = true;
        description = "";
      }
      // service;
    in
    s // { routes = normalizeRoutes s; };

  # The edge listener port on service hosts (ROUTING-PLAN §2.3). Keep in
  # sync with cli/routes.go edgePort.
  edgePort = 8443;

  allServices =
    dir:
    let
      entries = builtins.readDir dir;
      dirs = builtins.filter (
        d: entries.${d} == "directory" && builtins.pathExists (dir + "/${d}/service.nix")
      ) (builtins.attrNames entries);
    in
    map (d: normalize (import (dir + "/${d}/service.nix"))) dirs;

  # Public http routes reached through the edge (o002), each with `service`.
  # Services without a declared host are skipped (nothing to proxy to).
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
in
{
  inherit
    dataRoot
    persistList
    normalize
    normalizeRoute
    edgePort
    edgeRoutes
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

  # Every exposed http route with zone = "private" across all services in
  # `dir` (the containers directory). Each item is the normalized route plus
  # `service` (normalized service.nix). Read by h005 for the private zone's
  # DNS records and TLS-terminating vhosts (ROUTING-PLAN §2.2).
  privateRoutes =
    dir:
    let
      entries = builtins.readDir dir;
      dirs = builtins.filter (
        d: entries.${d} == "directory" && builtins.pathExists (dir + "/${d}/service.nix")
      ) (builtins.attrNames entries);
      services = map (d: normalize (import (dir + "/${d}/service.nix"))) dirs;
    in
    builtins.filter (r: r.proto == "http" && r.zone == "private" && r.exposure != "local") (
      builtins.concatMap (s: map (r: r // { service = s; }) (builtins.attrValues s.routes)) services
    );

  # DNS records for every exposed main-zone route, from service.nix
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
  # Private-zone routes are handled by privateRoutes (h005 terminates them).
  # Services without a host are skipped (nothing answers there).
  dnsRecords =
    { dir, hosts }:
    let
      routes = builtins.filter (r: r.exposure != "local" && r.fqdn != null && r.zone != "private") (
        builtins.concatMap (
          s:
          map (
            n:
            s.routes.${n}
            // {
              source = "${s.name}.${n}";
              host = s.host;
            }
          ) (builtins.attrNames s.routes)
        ) (builtins.filter (s: s.host != null) (allServices dir))
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
      tailnet = checked (
        map (r: {
          inherit (r) fqdn source;
          ip = overlayIp r;
        }) routes
      );
      lan = checked (
        map
          (r: {
            inherit (r) fqdn source;
            ip = hostIp r "lanIp";
          })
          (
            builtins.filter (
              r: (r.exposure == "lan" || r.exposure == "public") && hostIp r "lanIp" != null
            ) routes
          )
      );
      public = checked (
        map (r: {
          inherit (r) fqdn source;
          type = "CNAME";
          target = "${if builtins.elem "edge" r.via then "o002" else "home"}.${domain}";
        }) (builtins.filter (r: r.exposure == "public") routes)
      );
    };

  # WAN port forwards on the router (h005) for public `via = router`
  # tcp/udp routes (ROUTING-PLAN §2.4, §8 step 4). DNAT goes to the
  # service host's LAN IP, so the host must have one in fleet.nix.
  # Services without a host are skipped (no forward while inactive).
  # Returns [ { proto; port; host; ip; source; } ] sorted by proto/port;
  # two routes forwarding the same proto/port throw.
  routerForwards =
    { dir, hosts }:
    let
      fwds = builtins.concatMap (
        s:
        map
          (
            n:
            let
              r = s.routes.${n};
              ip = (hosts.${s.host} or { }).lanIp or null;
            in
            if ip == null then
              throw "routerForwards: ${s.name}.${n}: host ${s.host} has no lanIp in fleet.nix (the router can only forward to the LAN)"
            else
              {
                inherit (r) proto port;
                inherit ip;
                host = s.host;
                source = "${s.name}.${n}";
              }
          )
          (
            builtins.filter (
              n:
              let
                r = s.routes.${n};
              in
              r.exposure == "public" && r.proto != "http" && builtins.elem "router" r.via
            ) (builtins.attrNames s.routes)
          )
      ) (builtins.filter (s: s.host != null) (allServices dir));
      key = f: "${f.proto}/${toString f.port}";
      keys = map key fwds;
      dup = builtins.filter (k: builtins.length (builtins.filter (x: x == k) keys) > 1) keys;
    in
    if dup != [ ] then
      throw "routerForwards: ${builtins.head dup} is forwarded by two routes"
    else
      builtins.sort (a: b: key a < key b) fwds;

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
  #   guestNixpkgs           evaluate the guest with another nixpkgs (e.g.
  #                          26.05) while extra-container's host-side eval
  #                          stays on the flake's nixpkgs (25.11, issue #40).
  #   binds                  extra host paths, not part of persist/backups:
  #                          [ { host; container ? host; readOnly ? false; } ]
  #   devices                device nodes to pass through, e.g. [ "/dev/dri" ]
  #                          (bound and allowed rw in the container's cgroup)
  #   capabilities           extra nspawn capabilities, e.g. [ "CAP_NET_ADMIN" ]
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
      extraContainerConfig ? { },
    }:
    let
      svc =
        let
          s = normalize service;
        in
        if s.internet then
          s
        else
          throw "${s.name}: internet = false is only implemented for kind = \"podman\"";
      idmap = if privateUsers == "no" then "" else ":idmap";
      bindFlag =
        b: "--bind${if b.readOnly or false then "-ro" else ""}=${b.host}:${b.container or b.host}${idmap}";
    in
    {
      containers.${svc.name} = {
        ephemeral = true;
        autoStart = true;
        inherit privateUsers privateNetwork specialArgs;
        extraFlags =
          map (b: "--bind=${b.host}:${b.container}${idmap}") (persistList svc)
          ++ map bindFlag binds
          ++ map (d: "--bind=${d}") devices
          ++ map (c: "--capability=${c}") capabilities;
        allowedDevices = map (d: {
          node = if d == "/dev/dri" then "char-drm" else d;
          modifier = "rw";
        }) devices;
        config =
          { lib, ... }:
          {
            imports = [ config ];
            # With the host network the guest has no CAP_NET_ADMIN on the host
            # namespace (privateUsers), so its firewall can't load. The host
            # firewall is the one that counts; ports are opened by `containers`.
            networking.firewall.enable = lib.mkIf (!privateNetwork) (lib.mkForce false);
          };
      }
      // (if guestNixpkgs == null then { } else { nixpkgs = guestNixpkgs; })
      // extraContainerConfig;
      # Don't start (and stop) when a persist/bind source's mount is missing,
      # e.g. an unmounted /drives/wd10 would otherwise be bound as an empty dir.
      systemd.services."container@${svc.name}".unitConfig.RequiresMountsFor =
        map (b: b.host) (persistList svc) ++ map (b: b.host) binds;
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
      publish = map (
        port:
        let
          parts = lib.splitString ":" port;
        in
        "--publish=" + (if builtins.length parts == 2 then "127.0.0.1:${port}" else port)
      ) (p.ports or [ ]);
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
      ++ lib.optional (!svc.internet) "--network=fleet-noinet"
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
