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
        { name = "h001"; host = "10.12.14.10"; user = "luser"; keyFile = "/var/lib/openbao-secrets/nix2nix_2026-03-15"; }
        { name = "h002"; host = "10.12.14.183"; user = "luser"; keyFile = "/var/lib/openbao-secrets/nix2nix_2026-03-15"; }
      ];
    };
  };

  secrets = {
    nix2nix_2026-03-15 = {
      owner = "luser";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks = {
          "lio".identityFile = "$SECRET_PATH";
          "lio_".identityFile = "$SECRET_PATH";
          "oren".identityFile = "$SECRET_PATH";
          "juni".identityFile = "$SECRET_PATH";
          "gp3".identityFile = "$SECRET_PATH";
          "t".identityFile = "$SECRET_PATH";
          "t_".identityFile = "$SECRET_PATH";
          "h001".identityFile = "$SECRET_PATH";
          "h001_".identityFile = "$SECRET_PATH";
          "h002".identityFile = "$SECRET_PATH";
          "h002_".identityFile = "$SECRET_PATH";
          "h003".identityFile = "$SECRET_PATH";
          "h003_".identityFile = "$SECRET_PATH";
          "l001".identityFile = "$SECRET_PATH";
          "l002".identityFile = "$SECRET_PATH";
          "l002_".identityFile = "$SECRET_PATH";
          "o001".identityFile = "$SECRET_PATH";
          "o001_".identityFile = "$SECRET_PATH";
        };
      };
    };

    nix2github_2026-03-15 = {
      owner = "luser";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
      };
    };

    nix2gitforgejo_2026-03-15 = {
      owner = "luser";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks."git.joshuabell.xyz".identityFile = "$SECRET_PATH";
      };
    };

    headscale_auth_2026-03-15 = {
      softDepend = [ "tailscaled" ];
      configChanges = {
        services.tailscale.authKeyFile = "$SECRET_PATH";
      };
    };

    github_read_token_2026-03-15 = {
      configChanges = {
        nix.extraOptions = "!include $SECRET_PATH";
      };
    };
  };
}
