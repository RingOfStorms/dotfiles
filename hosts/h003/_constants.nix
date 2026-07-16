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
      # VLAN10
      { mac = "a8:29:48:94:23:dd"; name = "TL-SG1428PE"; ip = "10.12.16.2"; }
      # VLAN20
      { mac = "80:cc:9c:9e:e3:97"; name = "RAX70"; ip = "10.12.14.2"; }
      { mac = "94:83:C4:3C:AD:A0"; name = "AXT1800"; ip = "10.12.14.3"; }
      { mac = "00:be:43:b9:f4:e0"; name = "H001"; ip = "10.12.14.10"; }
      { mac = "54:04:a6:32:d1:71"; name = "H002"; ip = "10.12.14.183"; }
      { mac = "c8:c9:a3:2b:7b:19"; name = "PRUSA-MK4"; ip = "10.12.14.21"; }
      { mac = "24:e8:53:73:a3:c6"; name = "LGWEBOSTV"; ip = "10.12.14.30"; }
      { mac = "2c:cf:67:6a:45:47"; name = "HOMEASSISTANT"; ip = "10.12.14.22"; }
      { mac = "2a:d0:ec:fa:b9:7e"; name = "PIXEL-6"; ip = "10.12.14.31"; }
      { mac = "38:18:68:49:3c:48"; name = "ellawork-w"; ip = "10.12.14.122"; }
      { mac = "d4:a2:cd:39:4e:f0"; name = "ellawork-e"; ip = "10.12.14.132"; }
      { mac = "00:23:a4:0b:3b:be"; name = "TMREM"; ip = "10.12.14.181"; }
      { mac = "04:0e:3c:3a:0e:d1"; name = "JOE"; ip = "10.12.14.126"; }
      { mac = "01:ca:0c:47:ab:d7:4d"; name = "Jos_Mac"; ip = "10.12.14.159"; }
    ];

    # DNS split-horizon records (resolve to local IPs when on home network)
    localDnsRecords = [
      { hostname = "media.joshuabell.xyz"; ip = "10.12.14.10"; }
      { hostname = "jellyfin.joshuabell.xyz"; ip = "10.12.14.10"; }
    ];

    # ── Shared DNS upstreams (single source of truth) ──────────────────
    # Consumed by BOTH AdGuard (adguardhome.nix) and dnsmasq (networking.nix).
    # They accept different formats, so upstreams are split by kind:
    #
    #   plainIp   — bare IPs. Usable by dnsmasq (`server=`) AND AdGuard.
    #   encrypted — DoH/DoT/DoQ URLs. AdGuard ONLY (dnsmasq can't do encrypted).
    #
    # dnsmasq uses `plainIp` for the joshuabell.xyz fallthrough (names not in
    # localDnsRecords). AdGuard uses plainIp ++ encrypted as its global upstreams.
    #
    # NOTE: dnsmasq's fallthrough upstream MUST be external (never 127.0.0.1:53
    # / AdGuard) or it would create an AdGuard<->dnsmasq loop. `plainIp` is all
    # external resolvers, so it's safe.
    dnsUpstreams = {
      plainIp = [
        # Cloudflare
        "1.1.1.1"
        "1.0.0.1"
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
        # AdGuard unfiltered
        "94.140.14.140"
        "94.140.14.141"
        "2a10:50c0::1:ff"
        "2a10:50c0::2:ff"
      ];
      encrypted = [
        "https://unfiltered.adguard-dns.com/dns-query"
        "tls://unfiltered.adguard-dns.com"
        "quic://unfiltered.adguard-dns.com"
        "https://dns.cloudflare.com/dns-query"
        "tls://one.one.one.one"
      ];
    };
  };

  services = {
    adguardHome = {
      dataDir = "/var/lib/AdGuardHome";
    };

    dnsmasq = {
      dnsPort = 9053;
      # Upstreams for the joshuabell.xyz fallthrough live in the shared
      # network.dnsUpstreams.plainIp list (single source of truth, also used
      # by AdGuard). See networking.nix for where it's wired in.
    };

    ddns = {
      hostname = "home";
      domain = "joshuabell.xyz";
      # Check interval in minutes
      interval = 5;
    };

    # Run the measurement on h003's WAN-side router hardware, then publish
    # recorder-compatible entities to the Home Assistant Yellow on the LAN.
    ispSpeedtest = {
      hassUrl = "http://10.12.14.22:8123";
      tokenPath = "/var/lib/openbao-secrets/hass_isp_speedtest_token";
      entityPrefix = "sensor.isp_speedtest";
      interface = "enp1s0";
      onCalendar = "hourly";
      randomizedDelay = "5min";
      # Passed directly to GNU `timeout`, whose duration syntax uses `m`, not
      # systemd-style `min`.
      perServerTimeout = "5m";
      serviceTimeout = "20min";

      # Calibrated from Ookla's Chicago directory (2026-07-15). Pinning IDs
      # stops automatic server selection from drifting to distant locations.
      # Confirm sustained capacity after deployment and replace candidates that
      # cannot saturate the WAN link.
      servers = [
        { id = 50826; name = "Highline — Chicago, IL"; }
        { id = 14228; name = "Frontier — Chicago, IL"; }
        { id = 71947; name = "EZEE Fiber — Chicago, IL"; }
      ];
    };

    # Imperative extra-container services (not part of host nixos-rebuild)
    minecraft = {
      port = 25565; # Velocity proxy (vanilla MC default port) -- must match flakes/containers/minecraft/container.nix
      mapPort = 8080; # squaremap web UI -- proxied via nginx on port 80
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
    # Dedicated HA token for h003's scheduled speed-test publisher. Store the
    # actual long-lived token in OpenBao; it must not be committed to Nix.
    hass_isp_speedtest_token = {
      kvPath = "kv/data/machines/by-host/h003/hass_isp_speedtest_token";
      softDepend = [ "h003-isp-speedtest" ];
    };

    # bunny.net DNS API key — used by ./mods/ddns.nix to keep home.<domain>
    # pointed at the current WAN IP. Seeded declaratively by the OpenBao
    # reconciler (hosts/h001/mods/openbao/openbao-config.nix).
    bunny_rw_dns_2026-03-15 = { };
  };
}
