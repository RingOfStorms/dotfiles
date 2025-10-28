{
  config,
  lib,
  ...
}:
{
  networking = {
    # My Switch seems to not let me change management vlan so this is assume native default here for proper routing

    # Configure VLANs on the trunk interface (enp2s0)
    vlans = {
      vlan10 = {
        # management
        id = 10;
        interface = "enp2s0";
      };
      vlan20 = {
        # normal devices
        id = 20;
        interface = "enp2s0";
      };
    };

    # enable ipv6 or not
    enableIPv6 = true;

    # Interface configuration
    interfaces = {
      # WAN interface (physical enp1s0 - to modem)
      enp1s0 = {
        useDHCP = true; # Get IP from modem/ISP
        tempAddress = lib.mkIf config.networking.enableIPv6 "disabled"; # For IPv6 privacy
      };
      # LAN interface (VLAN 20 - main network)
      vlan20 = {
        ipv4.addresses = [
          {
            address = "10.12.14.1";
            prefixLength = 24;
          }
        ];
        ipv6.addresses = lib.mkIf config.networking.enableIPv6 [
          {
            address = "fd12:14:0::1"; # ULA prefix only
            prefixLength = 64;
          }
        ];
      };
      # Management VLAN 10
      vlan10 = {
        ipv4.addresses = [
          {
            address = "10.12.16.1"; # Management network
            prefixLength = 24;
          }
        ];
        ipv6.addresses = lib.mkIf config.networking.enableIPv6 [
          {
            address = "fd12:14:1::1";
            prefixLength = 64;
          }
        ];
      };
    };

    # NAT configuration
    nat = {
      enable = true;
      externalInterface = "enp1s0"; # WAN (physical)
      internalInterfaces = [
        "vlan10"
        "vlan20"
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
        iifname "vlan20" oifname "vlan10" drop
        iifname "vlan10" oifname "vlan20" drop

        # Explicitly allow LAN and Management to go to the WAN
        oifname "enp1s0" accept
        oifname "vlan10" accept

        # Drop any other forwarding attempts between internal networks
        drop
      '';

      interfaces = {
        # WAN interface - allow nothing inbound by default
        enp1s0 = {
          # Block all WAN
          allowedTCPPorts = [ ];
          allowedUDPPorts = [ ];
        };

        vlan10 = {
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
        vlan20 = {
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
        "vlan10"
        "vlan20"
      ];
      bind-interfaces = true;

      # Shift DNS to localhost only on a separate non standard port
      # We are using ./adguardhome.nix for DNS and we still run this one for reverse name lookups
      # Note in Ad GuardHome in DNS Settings add localhost:9053 to Private reverse DNS servers and enable them
      listen-address = "127.0.0.1";
      port = 9053;
      host-record = [
        "media.joshuabell.xyz,10.12.14.10"
        "jellyfin.joshuabell.xyz,10.12.14.10"
      ];
      address = [
        "/h001.local.joshuabell.xyz/10.12.14.10"
      ];

      # DHCP range and settings
      dhcp-range = [
        "set:mng,10.12.16.100,10.12.16.200,1h" # Management devices
        "set:lan,10.12.14.100,10.12.14.200,1h"
      ]
      ++ lib.optionals config.networking.enableIPv6 [
        "set:mng,fd12:14:1::100,fd12:14:1::200,64,6h" # For Management
        "set:lan,fd12:14::100,fd12:14::200,64,6h"
      ];
      dhcp-option = [
        "tag:mng,option:router,10.12.16.1"
        "tag:lan,option:router,10.12.14.1"
        "tag:mng,option:dns-server,10.12.16.1"
        "tag:lan,option:dns-server,10.12.14.1"
      ];

      # Static DHCP reservations
      dhcp-host = [
        "00:be:43:b9:f4:e0,H001,10.12.14.10"
        # TODO add H002 for .11
        "c8:c9:a3:2b:7b:19,PRUSA-MK4,10.12.14.21"
        "24:e8:53:73:a3:c6,LGWEBOSTV,10.12.14.30"
        "2c:cf:67:6a:45:47,HOMEASSISTANT,10.12.14.22"
        "2a:d0:ec:fa:b9:7e,PIXEL-6,10.12.14.31"
        "a8:29:48:94:23:dd,TL-SG1428PE,10.12.16.2"
        "00:23:a4:0b:3b:be,TMREM00004335,10.12.14.181"
        # Ellas work laptop
        "38:18:68:49:3c:48,ellawork-w,10.12.14.122"
        "d4:a2:cd:39:4e:f0,ellawork-e,10.12.14.132"
        # Josh Work laptop
        "00:23:a4:0b:3b:be,TMREM00004335,10.12.14.181"
      ];

      enable-ra = lib.mkIf config.networking.enableIPv6 true;
      # interface, min interval, max interval
      ra-param = lib.mkIf config.networking.enableIPv6 [
        "vlan10,60,120"
        "vlan20,60,120"
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
