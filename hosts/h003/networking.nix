{
  config,
  pkgs,
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
        # interface = "enp1s0";
      };
      vlan20 = {
        id = 20;
        interface = "bond0";
        # interface = "enp1s0";
      };
      vlan1 = {
        id = 1;
        interface = "bond0";
        # interface = "enp1s0";
      };
    };

    # enable ipv6 or not
    enableIPv6 = false;

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

      vlan1.ipv4.addresses = [
        {
          address = "192.168.0.2"; # Management network
          prefixLength = 24;
        }
      ];
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
        "10.12.14.100,10.12.14.200,24h" # LAN devices
        "192.168.0.10,192.168.0.50,24h" # Management devices
      ]
      ++ lib.optionals config.networking.enableIPv6 [
        # IPv6 DHCP range
        "fd12:14::100,fd12:14::200,64,24h"
      ];
      # dhcp-option = [
      #   "option:router,10.12.14.1"
      #   "option:dns-server,10.12.14.1,1.1.1.1,8.8.8.8"
      # ];

      # Static DHCP reservations
      dhcp-host = [
        "00:BE:43:B9:F4:E0,H001,10.12.14.10"
        # TODO add H002 for .11
        "C8:C9:A3:2B:7B:19,PRUSA-MK4,10.12.14.21"
        "24:E8:53:73:A3:C6,LGWEBOSTV,10.12.14.30"
        "2C:CF:67:6A:45:47,HOMEASSISTANT,10.12.14.22"
        "2A:D0:EC:FA:B9:7E,PIXEL-6,10.12.14.31"
      ];

      enable-ra = lib.mkIf config.networking.enableIPv6 true;
      ra-param = lib.mkIf config.networking.enableIPv6 "vlan20,60,120"; # interface, min interval, max interval

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
    # "net.ipv4.ip_forward" = 1;
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
