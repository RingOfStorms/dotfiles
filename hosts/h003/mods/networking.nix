{
  config,
  lib,
  pkgs,
  constants,
  fleet,
  ...
}:
let
  net = constants.network;
  mng = net.vlans.management;
  lan = net.vlans.lan;

  # ── Tailnet DNS-split instance parameters ──────────────────────────
  # h003's overlay IP (this box) — the tailnet dnsmasq listener binds here.
  # headscale routes joshuabell.xyz split-DNS to this IP (see o002/headscale.nix).
  h003Overlay = fleet.hosts.h003.overlayIp; # 100.64.0.14
  h001Overlay = fleet.hosts.h001.overlayIp; # 100.64.0.13
  # h001 service subdomains (single source of truth in fleet.nix).
  h001Services = fleet.h001Subdomains;

  # Fully-qualified Tailnet-only aliases cannot be represented by
  # `h001Subdomains` (which contains one-label public-zone service names).
  # Keep them in this split-DNS authority because ~joshuabell.xyz takes
  # precedence over MagicDNS's net.joshuabell.xyz zone.
  h001TailnetAliases = [ "secrets.h001.net.${fleet.global.domain}" ];

  # Tailnet clients get h001's OVERLAY ip for these names so they're reachable
  # from ANY tailnet client (home or remote), unlike the LAN 10.12.14.10 answer
  # the AdGuard/9053 path gives non-tailnet LAN clients.
  tailnetDnsmasqConf = pkgs.writeText "dnsmasq-tailnet.conf" ''
    # dnsmasq — TAILNET DNS-split instance (separate from the LAN instance).
    # Answers *.joshuabell.xyz for tailnet clients with h001's OVERLAY ip.
    # Bound ONLY to the overlay IP so it never affects LAN/DHCP DNS.
    # bind-dynamic (not bind-interfaces) tolerates the overlay IP appearing
    # AFTER dnsmasq starts (tailscaled boot race) — dnsmasq picks it up when
    # it comes up instead of hard-failing to bind.
    bind-dynamic
    listen-address=${h003Overlay}
    port=53
    # No resolv.conf, no /etc/hosts — pure authoritative + fallthrough.
    # (No dhcp-range defined here, so this instance serves no DHCP.)
    no-resolv
    no-hosts
    # All h001 service names -> h001 overlay IP.
    ${lib.concatMapStringsSep "\n"
      (n: "host-record=${n}.${fleet.global.domain},${h001Overlay}")
      h001Services}

    # Keep listed service names local for every RR type. `host-record` supplies
    # the local A/PTR data; without this rule, AAAA/CNAME/HTTPS queries fall
    # through to the public CNAME chain and can poison client resolver caches.
    ${lib.concatMapStringsSep "\n"
      (n: "local=/${n}.${fleet.global.domain}/")
      h001Services}

    # Fully-qualified Tailnet-only aliases -> h001 overlay IP.
    ${lib.concatMapStringsSep "\n"
      (n: "host-record=${n},${h001Overlay}")
      h001TailnetAliases}

    # Fallthrough: any other joshuabell.xyz name -> external resolvers
    # (domain-scoped; never AdGuard/127.0.0.1:53 -> no loop).
    ${lib.concatMapStringsSep "\n"
      (u: "server=/${fleet.global.domain}/${u}")
      net.dnsUpstreams.plainIp}
  '';
in
{
  networking = {
    # My Switch seems to not let me change management vlan so this is assume native default here for proper routing

    # Configure VLANs on the trunk interface (enp2s0)
    vlans = {
      ${mng.name} = {
        # management
        id = mng.id;
        interface = net.trunkInterface;
      };
      ${lan.name} = {
        # normal devices
        id = lan.id;
        interface = net.trunkInterface;
      };
    };

    # enable ipv6 or not
    enableIPv6 = true;

    # Interface configuration
    interfaces = {
      # WAN interface (physical enp1s0 - to modem)
      ${net.wanInterface} = {
        useDHCP = true; # Get IP from modem/ISP
        tempAddress = lib.mkIf config.networking.enableIPv6 "disabled"; # For IPv6 privacy
      };
      # LAN interface (VLAN 20 - main network)
      ${lan.name} = {
        ipv4.addresses = [
          {
            address = lan.ipv4;
            prefixLength = lan.ipv4Prefix;
          }
        ];
        ipv6.addresses = lib.mkIf config.networking.enableIPv6 [
          {
            address = lan.ipv6; # ULA prefix only
            prefixLength = lan.ipv6Prefix;
          }
        ];
      };
      # Management VLAN 10
      ${mng.name} = {
        ipv4.addresses = [
          {
            address = mng.ipv4; # Management network
            prefixLength = mng.ipv4Prefix;
          }
        ];
        ipv6.addresses = lib.mkIf config.networking.enableIPv6 [
          {
            address = mng.ipv6;
            prefixLength = mng.ipv6Prefix;
          }
        ];
      };
    };

    # NAT configuration
    nat = {
      enable = true;
      externalInterface = net.wanInterface; # WAN (physical)
      internalInterfaces = [
        mng.name
        lan.name
      ]; # LAN/Management
      enableIPv6 = lib.mkIf config.networking.enableIPv6 true; # Enable IPv6 NAT
    };

    # Enable IP forwarding for routing
    firewall = {
      enable = true;
      allowPing = true; # For ddiagnostics

      # Block vlan to vlan communication
      filterForward = true;
      extraForwardRules = ''
        # Allow established connections (allows return traffic)
        ip protocol tcp ct state {established, related} accept
        ip protocol udp ct state {established, related} accept
        ip6 nexthdr tcp ct state {established, related} accept
        ip6 nexthdr udp ct state {established, related} accept

        # --- Inter-VLAN Security ---
        # Block any NEW connection attempts between LAN and Management
        iifname "${lan.name}" oifname "${mng.name}" drop
        iifname "${mng.name}" oifname "${lan.name}" drop

        # Explicitly allow LAN and Management to go to the WAN
        oifname "${net.wanInterface}" accept
        oifname "${mng.name}" accept

        # Drop any other forwarding attempts between internal networks
        drop
      '';

      interfaces = {
        # WAN interface - allow nothing inbound by default
        ${net.wanInterface} = {
          # Block all WAN except port-forwarded services.
          # Note: Minecraft (25565) is opened globally via hosts/h003/containers.nix
          # using constants.services.minecraft.port -- no entry needed here.
          allowedTCPPorts = [ ];
          allowedUDPPorts = [ ];
        };

        ${mng.name} = {
          allowedTCPPorts = [
            22 # SSH (for remote admin access)
            53 # DNS
            80
            443 # HTTP
          ];
          allowedUDPPorts = [
            53 # DNS
            67 # DHCP server
            68
          ];
        };

        # LAN interface (VLAN 20) - FULL SERVICE
        ${lan.name} = {
          allowedTCPPorts = [
            22 # SSH (if you want to SSH to your router from LAN devices)
            53 # DNS queries
            80
            443 # HTTP (for local web services)
          ];
          allowedUDPPorts = [
            53 # DNS queries
            67 # DHCP server (dnsmasq)
            68 # DHCP client responses
          ];
        };
      };
    };

    # example of port forwarding
    # nat.forwardPorts = [
    #   {
    #     destination = "10.12.14.50:8080";
    #     proto = "tcp";
    #     sourcePort = 8080;
    #   }
    # ];
  };

  # dnsmasq for DHCP + DNS
  services.dnsmasq = {
    enable = true;
    alwaysKeepRunning = true;
    settings = {
      # Listen only on LAN interface
      interface = [
        mng.name
        lan.name
      ];
      bind-interfaces = true;

      # dnsmasq is the authoritative resolver for the whole joshuabell.xyz zone.
      # AdGuard routes that entire zone here with ONE upstream line (see
      # adguardhome.nix):  [/joshuabell.xyz/]127.0.0.1:9053
      # so ALL local DNS for joshuabell.xyz is configured HERE, declaratively,
      # via `localDnsRecords` — single source of truth, no per-name AdGuard UI.
      listen-address = "127.0.0.1";
      port = constants.services.dnsmasq.dnsPort;

      # Local records: these names resolve to the configured IP. Any
      # joshuabell.xyz name NOT listed falls through to `server=` below.
      host-record =
        map (r: "${r.hostname},${r.ip}") net.localDnsRecords;

      # Fallthrough for joshuabell.xyz names not in host-record: forward to the
      # shared external plain-IP upstreams. Domain-scoped so dnsmasq only
      # forwards THIS zone (it is not a general recursive resolver). Must be
      # external resolvers (never AdGuard :53) to avoid an AdGuard<->dnsmasq
      # loop; net.dnsUpstreams.plainIp is all external, so this is safe.
      # TRADEOFF: these fallthrough lookups bypass AdGuard filtering (fine for
      # our own domain).
      server = map (u: "/joshuabell.xyz/${u}") net.dnsUpstreams.plainIp;

      # DHCP range and settings
      dhcp-range = [
        "set:mng,${mng.dhcpRange.start},${mng.dhcpRange.end},${mng.dhcpRange.lease}" # Management devices
        "set:lan,${lan.dhcpRange.start},${lan.dhcpRange.end},${lan.dhcpRange.lease}"
      ]
      ++ lib.optionals config.networking.enableIPv6 [
        "set:mng,${mng.dhcpRange.ipv6Start},${mng.dhcpRange.ipv6End},${toString mng.ipv6Prefix},${mng.dhcpRange.ipv6Lease}" # For Management
        "set:lan,${lan.dhcpRange.ipv6Start},${lan.dhcpRange.ipv6End},${toString lan.ipv6Prefix},${lan.dhcpRange.ipv6Lease}"
      ];
      dhcp-option = [
        "tag:mng,option:router,${mng.ipv4}"
        "tag:lan,option:router,${lan.ipv4}"
        "tag:mng,option:dns-server,${mng.ipv4}"
        "tag:lan,option:dns-server,${lan.ipv4}"
      ];

      # Static DHCP reservations
      dhcp-host = map (l: "${l.mac},${l.name},${l.ip}") net.staticLeases;

      enable-ra = lib.mkIf config.networking.enableIPv6 true;
      # interface, min interval, max interval
      ra-param = lib.mkIf config.networking.enableIPv6 [
        "${mng.name},60,120"
        "${lan.name},60,120"
      ];

      # DNS settings (not needed since we use adguard for dns)
      # server = [
      #   "1.1.1.1"
      #   "8.8.8.8"
      #   "2606:4700:4700::1111" # Cloudflare IPv6
      #   "2001:4860:4860::8888" # Google IPv6
      # ];
    };
  };

  # ── Second dnsmasq instance: TAILNET DNS split ─────────────────────
  # The NixOS services.dnsmasq module is single-instance, and a single dnsmasq
  # can't answer the SAME name two different ways by source. LAN clients need
  # media/jellyfin -> 10.12.14.10 (via AdGuard -> the :9053 instance above);
  # tailnet clients need *.joshuabell.xyz -> h001 OVERLAY (100.64.0.13) so the
  # names are reachable from anywhere on the tailnet.
  #
  # So this is a SEPARATE dnsmasq bound ONLY to h003's overlay IP
  # (100.64.0.14:53). headscale split-DNS routes joshuabell.xyz here for tailnet
  # clients (see hosts/oracle/o002/headscale.nix). It never touches LAN/DHCP.
  systemd.services.dnsmasq-tailnet = {
    description = "dnsmasq (tailnet DNS-split for *.joshuabell.xyz -> h001 overlay)";
    # Needs the overlay IP to exist -> tailscaled up first.
    after = [ "network.target" "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq -k --conf-file=${tailnetDnsmasqConf}";
      # Bind-fail if the overlay IP isn't up yet -> retry until tailscale is ready.
      Restart = "always";
      RestartSec = 5;
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  boot.kernel.sysctl = {
    # Enable IPv4 forwarding
    "net.ipv4.conf.all.forwarding" = true;
    # Enable IPv6 forwarding
    "net.ipv6.conf.all.forwarding" = true;

    # Security hardening
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
  };
}
