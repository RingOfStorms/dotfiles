{
  config,
  lib,
  constants,
  ...
}:
let
  net = constants.network;
  mng = net.vlans.management;
  lan = net.vlans.lan;
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
          # Block all WAN
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

      # Shift DNS to localhost only on a separate non standard port
      # We are using ./adguardhome.nix for DNS and we still run this one for reverse name lookups
      # Note in Ad GuardHome in DNS Settings add localhost:9053 to Private reverse DNS servers and enable them
      listen-address = "127.0.0.1";
      port = constants.services.dnsmasq.dnsPort;
      # NOTE these make it so my other devices don't hit the open net to stream movies
      # while on the local network. Note that this is being paired with stateful settings
      # in Adguardhome upstream dns servers:
      # [/media.joshuabell.xyz/]127.0.0.1:9053
      # [/jellyfin.joshuabell.xyz/]127.0.0.1:9053
      host-record =
        # DNS splitting on local network
        # Basically these are intercepted and resolve to local IP's when anyone is connected to home network
        map (r: "${r.hostname},${r.ip}") net.localDnsRecords;

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
