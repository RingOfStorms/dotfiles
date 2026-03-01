# Service constants for h003 (Router)
# Single source of truth for ports, IPs, DHCP, and network configuration.
{
  host = {
    name = "h003";
    overlayIp = "100.64.0.14";
    primaryUser = "luser";
    stateVersion = "25.05";
  };

  network = {
    wanInterface = "enp1s0";
    trunkInterface = "enp2s0";

    vlans = {
      management = {
        id = 10;
        name = "vlan10";
        ipv4 = "10.12.16.1";
        ipv4Prefix = 24;
        ipv6 = "fd12:14:1::1";
        ipv6Prefix = 64;
        dhcpRange = {
          start = "10.12.16.100";
          end = "10.12.16.200";
          lease = "1h";
          ipv6Start = "fd12:14:1::100";
          ipv6End = "fd12:14:1::200";
          ipv6Lease = "6h";
        };
      };
      lan = {
        id = 20;
        name = "vlan20";
        ipv4 = "10.12.14.1";
        ipv4Prefix = 24;
        ipv6 = "fd12:14:0::1";
        ipv6Prefix = 64;
        dhcpRange = {
          start = "10.12.14.100";
          end = "10.12.14.200";
          lease = "1h";
          ipv6Start = "fd12:14::100";
          ipv6End = "fd12:14::200";
          ipv6Lease = "6h";
        };
      };
    };

    # Static DHCP reservations
    staticLeases = [
      { mac = "00:be:43:b9:f4:e0"; name = "H001"; ip = "10.12.14.10"; }
      { mac = "54:04:a6:32:d1:71"; name = "H002"; ip = "10.12.14.183"; }
      { mac = "c8:c9:a3:2b:7b:19"; name = "PRUSA-MK4"; ip = "10.12.14.21"; }
      { mac = "24:e8:53:73:a3:c6"; name = "LGWEBOSTV"; ip = "10.12.14.30"; }
      { mac = "2c:cf:67:6a:45:47"; name = "HOMEASSISTANT"; ip = "10.12.14.22"; }
      { mac = "2a:d0:ec:fa:b9:7e"; name = "PIXEL-6"; ip = "10.12.14.31"; }
      { mac = "a8:29:48:94:23:dd"; name = "TL-SG1428PE"; ip = "10.12.16.2"; }
      { mac = "38:18:68:49:3c:48"; name = "ellawork-w"; ip = "10.12.14.122"; }
      { mac = "d4:a2:cd:39:4e:f0"; name = "ellawork-e"; ip = "10.12.14.132"; }
      { mac = "00:23:a4:0b:3b:be"; name = "TMREM00004335"; ip = "10.12.14.181"; }
    ];

    # DNS split-horizon records (resolve to local IPs when on home network)
    localDnsRecords = [
      { hostname = "media.joshuabell.xyz"; ip = "10.12.14.10"; }
      { hostname = "jellyfin.joshuabell.xyz"; ip = "10.12.14.10"; }
    ];
  };

  services = {
    adguardHome = {
      dataDir = "/var/lib/AdGuardHome";
    };

    dnsmasq = {
      dnsPort = 9053;
    };

    ups = {
      driver = "usbhid-ups";
      vendorId = "051D";
      productId = "0002";
      description = "APC Back-UPS XS 1500M";
      # Remote hosts to shut down on critical battery
      remoteShutdownHosts = [
        { name = "h001"; host = "10.12.14.10"; user = "luser"; keyFile = "/run/agenix/nix2h001"; }
        { name = "h002"; host = "10.12.14.183"; user = "luser"; keyFile = "/run/agenix/nix2nix"; }
      ];
    };
  };
}
