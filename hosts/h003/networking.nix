{
  config,
  lib,
  ...
}:
{
  networking = {
    # Configure bonding (LAG)
    bonds = {
      bond0 = {
        interfaces = [
          "enp1s0"
          "enp2s0"
        ];
        driverOptions = {
          mode = "802.3ad"; # LACP
          miimon = "100";
          lacp_rate = "fast";
        };
      };
    };

    # Configure VLANs on the bonded interface
    vlans = {
      vlan10 = {
        id = 10;
        interface = "bond0";
      };
      vlan20 = {
        id = 20;
        interface = "bond0";
      };
      vlan1 = {
        id = 1;
        interface = "bond0";
      };
    };

    # enable ipv6 or not
    enableIPv6 = true;

    # Interface configuration
    interfaces = {
      # WAN interface (VLAN 10 - to modem)
      vlan10 = {
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
            address = "fd12:14::1"; # ULA prefix only
            prefixLength = 64;
          }
        ];
      };

      vlan1 = {
        ipv4.addresses = [
          {
            address = "10.12.16.1"; # Management network
            prefixLength = 24;
          }
        ];
        ipv6.addresses = lib.mkIf config.networking.enableIPv6 [
          {
            address = "fd12:14::1::1";
            prefixLength = 64;
          }
        ];
      };
    };

    # NAT configuration
    nat = {
      enable = true;
      externalInterface = "vlan10"; # WAN
      internalInterfaces = [
        "vlan20"
        "vlan1"
      ]; # LAN
      enableIPv6 = lib.mkIf config.networking.enableIPv6 true; # Enable IPv6 NAT
    };

    # Enable IP forwarding for routing
    firewall = {
      enable = true;
      allowPing = true; # For ddiagnostics

      trustedInterfaces = [
        "vlan20" # Allow all on LAN
        "vlan1" # Allow all on management
      ];

      # Block vlan to vlan communication
      filterForward = true;
      # extraForwardRules = ''
      #   ip saddr 10.12.14.0/24 ip daddr 10.12.16.0/24 drop
      #   ip6 saddr fd12:14::/64 ip6 daddr fd12:14:1::/64 drop
      # '';

      interfaces = {
        # WAN interface - allow nothing inbound by default
        vlan10 = {
          # Block all WAN
          allowedTCPPorts = [ ];
          allowedUDPPorts = [ ];
        };

        # # LAN interface (VLAN 20) - FULL SERVICE
        # vlan20 = {
        #   allowedTCPPorts = [
        #     22 # SSH (if you want to SSH to your router from LAN devices)
        #     53 # DNS queries
        #     80 # HTTP (for local web services)
        #     443 # HTTPS (for local web services)
        #     # Add other services you run locally (Plex, Home Assistant, etc.)
        #   ];
        #   allowedUDPPorts = [
        #     53 # DNS queries
        #     67 # DHCP server (dnsmasq)
        #     68 # DHCP client responses
        #     # 123 # NTP (if you run a time server)
        #   ];
        # };
        #
        # # Management interface (VLAN 1) - LIMITED SERVICE
        # vlan1 = {
        #   allowedTCPPorts = [
        #     22 # SSH (for remote admin access)
        #     53 # DNS
        #     80 # HTTP (to access switch web interface through the router)
        #     443
        #     # HTTPS
        #   ];
        #   allowedUDPPorts = [
        #     53 # DNS
        #     67 # DHCP server
        #     68
        #     # DHCP client
        #   ];
        # };
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
        "vlan20"
        "vlan1"
      ];
      bind-interfaces = true;

      # DHCP range and settings
      dhcp-range = [
        "10.12.14.100,10.12.14.200,6h" # LAN devices
        "10.12.16.100,10.12.16.200,6h" # Management devices
      ]
      ++ lib.optionals config.networking.enableIPv6 [
        "fd12:14::100,fd12:14::200,64,6h" # For LAN (vlan20)
        "fd12:14:1::100,fd12:14:1::200,64,6h" # For Management (vlan1)
      ];
      # dhcp-option = [
      #   "option:router,10.12.14.1"
      #   "option:dns-server,10.12.14.1,1.1.1.1,8.8.8.8"
      # ];

      # Static DHCP reservations
      dhcp-host = [
        "00:be:43:b9:f4:e0,H001,10.12.14.10"
        # TODO add H002 for .11
        "c8:c9:a3:2b:7b:19,PRUSA-MK4,10.12.14.21"
        "24:e8:53:73:a3:c6,LGWEBOSTV,10.12.14.30"
        "2c:cf:67:6a:45:47,HOMEASSISTANT,10.12.14.22"
        "2a:d0:ec:fa:b9:7e,PIXEL-6,10.12.14.31"
        "01:a8:29:48:94:23:dd,TL-SG1428PE,192.168.0.1"
      ];

      enable-ra = lib.mkIf config.networking.enableIPv6 true;
      # interface, min interval, max interval
      ra-param = lib.mkIf config.networking.enableIPv6 [
        "vlan20,60,120"
        "vlan1,60,120"
      ];

      # DNS settings
      server = [
        # TODO ad guard
        "1.1.1.1"
        "8.8.8.8"
        "2606:4700:4700::1111" # Cloudflare IPv6
        "2001:4860:4860::8888" # Google IPv6
      ];
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
