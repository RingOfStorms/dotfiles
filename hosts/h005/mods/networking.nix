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
  # h005's overlay IP (this box, constants.host.overlayIp) — the tailnet dnsmasq listener binds here.
  # headscale routes joshuabell.xyz split-DNS to this IP (see o002/headscale.nix).
  selfOverlay = constants.host.overlayIp; # h005 (100.64.0.3)

  # Service names: generated from containers/*/service.nix routes plus the
  # few hand-kept ones (../dns-records.nix). Tailnet answers are the serving
  # host's overlay IP; LAN answers its LAN IP.
  dnsRecords = import ../dns-records.nix { inherit fleet; };

  # ── Private zone ts.joshuabell.xyz (ROUTING-PLAN §2.2) ─────────────
  # Generated from the containers inventory in this repo (working tree, not
  # the pushed containers input): every http route with zone = "private"
  # and exposure != "local". h005's nginx terminates TLS for these names
  # (hosts/h005/private-zone.nix), so they resolve to h005's overlay IP.
  # The zone is answered locally only: unknown ts names get NXDOMAIN and
  # never reach public DNS.
  privateZone = "ts.${fleet.global.domain}";
  privateRoutes = (import ../../../containers/lib.nix).privateRoutes ../../../containers;

  # Tailnet clients get the OVERLAY ip of the host serving each listed name
  # (h001 or lio) so they're reachable from ANY tailnet client (home or
  # remote), unlike the LAN answer the AdGuard/9053 path gives non-tailnet LAN
  # clients.
  tailnetDnsmasqConf = pkgs.writeText "dnsmasq-tailnet.conf" ''
    # dnsmasq — TAILNET DNS-split instance (separate from the LAN instance).
    # Answers listed *.joshuabell.xyz service names for tailnet clients with
    # the OVERLAY ip of the host that serves them (h001 or lio).
    # Bound ONLY to the overlay IP so it never affects LAN/DHCP DNS.
    # bind-dynamic (not bind-interfaces) tolerates the overlay IP appearing
    # AFTER dnsmasq starts (tailscaled boot race) — dnsmasq picks it up when
    # it comes up instead of hard-failing to bind.
    bind-dynamic
    listen-address=${selfOverlay}
    port=53
    # No resolv.conf, no /etc/hosts — pure authoritative + fallthrough.
    # (No dhcp-range defined here, so this instance serves no DHCP.)
    no-resolv
    no-hosts
    # Service names -> serving host's overlay IP (../dns-records.nix).
    ${lib.concatMapStringsSep "\n" (r: "host-record=${r.fqdn},${r.ip}") dnsRecords.tailnet}

    # Keep listed service names local for every RR type. `host-record` supplies
    # the local A/PTR data; without this rule, AAAA/CNAME/HTTPS queries fall
    # through to the public CNAME chain and can poison client resolver caches.
    ${lib.concatMapStringsSep "\n" (r: "local=/${r.fqdn}/") dnsRecords.tailnet}

    # Private tailnet-only zone: answered here only (NXDOMAIN for unknown
    # names, never forwarded to public DNS). Names point at h005, whose
    # nginx terminates TLS with *.${privateZone}.
    local=/${privateZone}/
    ${lib.concatMapStringsSep "\n" (r: "host-record=${r.fqdn},${selfOverlay}") privateRoutes}

    # Fallthrough: any other joshuabell.xyz name -> external resolvers
    # (domain-scoped; never AdGuard/127.0.0.1:53 -> no loop).
    ${lib.concatMapStringsSep "\n" (u: "server=/${fleet.global.domain}/${u}") net.dnsUpstreams.plainIp}
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

    # NixOS's forward-allow chain accepts ICMPv6 before extraForwardRules.
    # Enforce topology first so that exemption cannot bypass VLAN isolation.
    nftables.tables.router-isolation = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter - 10; policy drop;
          iifname "${lan.name}" oifname "${mng.name}" drop
          iifname "${mng.name}" oifname "${lan.name}" drop
          ct state invalid drop
          ${lib.concatMapStringsSep "\n          " (
            d: ''ether saddr ${d.mac} counter drop comment "wanDenied ${d.name}"''
          ) net.wanDenied}
          ct state { established, related } accept
          ${config.ringofstorms.router.forwardRules}
          iifname "${mng.name}" oifname "${net.wanInterface}" accept
          iifname "${lan.name}" oifname "${net.wanInterface}" accept
        }

        # The forward drop above only covers routed packets. A denied device can
        # still reach the router itself, whose AdGuard listener forwards DNS to
        # external upstreams: that path is INPUT -> OUTPUT and never traverses
        # the forward chain. Close it here, at a lower priority than the NixOS
        # input chain so nothing earlier can accept first.
        # Only DNS (53) is blocked - DHCP (67/68/547), NDP and ICMPv6 keep
        # working, so the device stays addressable and same-VLAN control is
        # unaffected.
        chain input {
          type filter hook input priority filter - 5; policy accept;
          ${lib.concatMapStringsSep "\n          " (
            d: ''ether saddr ${d.mac} udp dport 53 counter drop comment "wanDenied ${d.name} dns/udp"''
          ) net.wanDenied}
          ${lib.concatMapStringsSep "\n          " (
            d: ''ether saddr ${d.mac} tcp dport 53 counter drop comment "wanDenied ${d.name} dns/tcp"''
          ) net.wanDenied}
        }
      '';
    };

    # Enable IP forwarding for routing
    firewall = {
      enable = true;
      allowPing = true; # For ddiagnostics

      # Block vlan to vlan communication
      filterForward = true;
      extraForwardRules = ''
        # NixOS accepts established/related flows in its base forward chain.
        # New flows may leave only the two internal VLANs towards the WAN.
        iifname "${mng.name}" oifname "${net.wanInterface}" accept
        iifname "${lan.name}" oifname "${net.wanInterface}" accept

        # Drop any other forwarding attempts between internal networks
        drop
      '';

      interfaces = {
        # WAN interface - allow nothing inbound by default
        ${net.wanInterface} = {
          # Nothing on h005 itself is open to the WAN. Port forwards to LAN hosts
          # are DNAT (../router-forwards.nix), not input rules.
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
          ]
          ++ lib.optionals config.networking.enableIPv6 [ 547 ]; # DHCPv6 server
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
          ]
          ++ lib.optionals config.networking.enableIPv6 [ 547 ]; # DHCPv6 server
        };
      };
    };

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
      # via ../dns-records.nix (generated from container routes + a few hand
      # names) — no per-name AdGuard UI.
      listen-address = "127.0.0.1";
      port = constants.services.dnsmasq.dnsPort;

      # Local records: these names resolve to the configured IP. Any
      # joshuabell.xyz name NOT listed falls through to `server=` below.
      host-record = map (r: "${r.fqdn},${r.ip}") dnsRecords.lan;

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
      ]
      ++ lib.optionals config.networking.enableIPv6 [
        # Explicit DHCPv6 option 23 and RA RDNSS: clients must use AdGuard's
        # VLAN addresses on port 53, not dnsmasq's DNS listener on 9053.
        "tag:mng,option6:dns-server,[${mng.ipv6}]"
        "tag:lan,option6:dns-server,[${lan.ipv6}]"
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
  # tailnet clients need listed *.joshuabell.xyz names -> the serving host's
  # OVERLAY ip (h001 or lio) so the names are reachable from anywhere on the
  # tailnet.
  #
  # So this is a SEPARATE dnsmasq bound ONLY to this host's (h005) overlay IP
  # (constants.host.overlayIp:53). headscale split-DNS routes joshuabell.xyz here for tailnet
  # clients (see hosts/oracle/o002/headscale.nix). It never touches LAN/DHCP.
  systemd.services.dnsmasq-tailnet = {
    description = "dnsmasq (tailnet DNS-split for *.joshuabell.xyz -> serving host's overlay)";
    # Needs the overlay IP to exist -> tailscaled up first.
    after = [
      "network.target"
      "tailscaled.service"
    ];
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

  # bcachefs-impermanence boots with systemd in the initrd. systemd-sysctl runs
  # there with the initrd's sysctl.d and stays "active" across switch-root, so
  # the system's boot.kernel.sysctl (including forwarding) is never applied.
  # Observed 2026-10-15: first router boot came up with forwarding = 0.
  systemd.services.sysctl-reapply-after-initrd = {
    description = "Re-apply system sysctl.d after switch-root";
    wantedBy = [ "sysinit.target" ];
    after = [
      "systemd-sysctl.service"
      "systemd-modules-load.service"
    ];
    before = [
      "sysinit.target"
      "network-pre.target"
      "shutdown.target"
    ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-sysctl";
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
