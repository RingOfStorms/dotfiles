# Service constants for h005 (router replacing h003; bcachefs root + impermanence).
# Router services stay disabled on the bench. Enable only at the coordinated
# cutover in readme.md; gateway addresses must never overlap the live h003.
{
  host = {
    name = "h005";
    overlayIp = "100.64.0.3";
    primaryUser = "luser";
    stateVersion = "26.05";
  };

  # Pinned SSH host keys of push targets (ssh-keyscan over the tailnet,
  # 2026-10-21), used by wildcard-cert.nix and fleet-edge.nix. A rebuilt
  # target needs its new key here before pushes work again.
  pinnedHostKeys = {
    o002 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAf4Tfw9fhqQ2oUwM7jGSkpvxdTCsFVlThVVpf8FoU08";
    h001 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGTAz6n35c3r8kSuWJM1JzMVx6jK+0EBwpJA5eTIvy3N";
  };

  network = {
    routerEnable = true;

    # Physically labelled on the case.
    wanInterface = "enp1s0"; # 00:ce:39:d8:0c:17 -> modem
    trunkInterface = "enp2s0"; # 00:ce:39:d8:0c:18 -> SG3210X Tw1/0/8 (802.1Q trunk)

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
      # VLAN10 (management)
      # Core managed switch (Omada SG3210X-M2). Mgmt IP is ALSO set statically
      # on the switch itself (interface vlan 10 -> 10.12.16.2); this reservation
      # documents it and keeps dnsmasq from ever handing 10.12.16.2 to anything.
      {
        mac = "a8:29:48:e9:b2:ec";
        name = "SG3210X-M2";
        ip = "10.12.16.2";
      }
      # VLAN20 (lan)
      # Easy Smart PoE switch, factory-reset -> flat/untagged, extends VLAN 20
      # off SG3210X Te1/0/10. Reservation only takes effect if DHCP is enabled
      # in the SG1428PE web UI (Easy Smart switches default to static 192.168.0.1).
      {
        mac = "a8:29:48:94:23:dd";
        name = "TL-SG1428PE";
        ip = "10.12.14.4";
      }
      {
        mac = "80:cc:9c:9e:e3:97";
        name = "RAX70";
        ip = "10.12.14.2";
      }
      {
        mac = "94:83:C4:3C:AD:A0";
        name = "AXT1800";
        ip = "10.12.14.3";
      }
      {
        mac = "00:be:43:b9:f4:e0";
        name = "H001";
        ip = "10.12.14.10";
      }
      {
        mac = "30:56:0f:4f:52:5f";
        name = "H004";
        ip = "10.12.14.184";
      }
      {
        mac = "c8:c9:a3:2b:7b:19";
        name = "PRUSA-MK4";
        ip = "10.12.14.21";
      }
      {
        mac = "24:e8:53:73:a3:c6";
        name = "LGWEBOSTV";
        ip = "10.12.14.30";
      }
      {
        mac = "2c:cf:67:6a:45:47";
        name = "HOMEASSISTANT";
        ip = "10.12.14.22";
      }
      {
        mac = "2a:d0:ec:fa:b9:7e";
        name = "PIXEL-6";
        ip = "10.12.14.31";
      }
      {
        mac = "38:18:68:49:3c:48";
        name = "ellawork-w";
        ip = "10.12.14.122";
      }
      {
        mac = "d4:a2:cd:39:4e:f0";
        name = "ellawork-e";
        ip = "10.12.14.132";
      }
      {
        mac = "00:23:a4:0b:3b:be";
        name = "TMREM";
        ip = "10.12.14.181";
      }
      {
        mac = "04:0e:3c:3a:0e:d1";
        name = "JOE";
        ip = "10.12.14.126";
      }
      {
        mac = "01:ca:0c:47:ab:d7:4d";
        name = "Jos_Mac";
        ip = "10.12.14.159";
      }
    ];

    # Devices that may talk on their VLAN but must never reach the internet
    # (IPv4 or IPv6). Matched by source MAC in the router-isolation forward
    # chain, before the established/related accept, so existing flows die too.
    # Same-VLAN traffic (e.g. Home Assistant <-> TV on vlan20) is switched at
    # L2 and never hits this chain, so LAN control is unaffected.
    wanDenied = [
      # LG 75UN9070AUD: telemetry/ACR/ads/OTA. HA controls it locally (ssap :3001).
      {
        mac = "24:e8:53:73:a3:c6";
        name = "LGWEBOSTV";
      }
    ];

    # ── Shared DNS upstreams (single source of truth) ──────────────────
    # Consumed by BOTH AdGuard (adguardhome.nix) and dnsmasq (networking.nix).
    # They accept different formats, so upstreams are split by kind:
    #
    #   plainIp   — bare IPs. Usable by dnsmasq (`server=`) AND AdGuard.
    #   encrypted — DoH/DoT/DoQ URLs. AdGuard ONLY (dnsmasq can't do encrypted).
    #
    # dnsmasq uses `plainIp` for the joshuabell.xyz fallthrough (names not in
    # hosts/h005/dns-records.nix). AdGuard uses plainIp ++ encrypted as its global upstreams.
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
      tokenPath = "/var/lib/secrets_manager_hydrated/bunny_rw_dns_2026-03-15";
    };

    # Run the measurement on h005's WAN-side router hardware, then publish
    # recorder-compatible entities to the Home Assistant Yellow on the LAN.
    ispSpeedtest = {
      hassUrl = "http://10.12.14.22:8123";
      tokenPath = "/var/lib/secrets_manager_hydrated/hass_isp_speedtest_token";
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
        {
          id = 50826;
          name = "Highline — Chicago, IL";
        }
        {
          id = 14228;
          name = "Frontier — Chicago, IL";
        }
        {
          id = 71947;
          name = "EZEE Fiber — Chicago, IL";
        }
      ];
    };

    ups = {
      # Physical UPS units attached to h005 over USB. The attribute name is the
      # NUT ups name (shows up as "<name>@localhost" in logs and upsc).
      #
      # Both units are the same model, so vendorid/productid alone cannot tell
      # them apart -- the USB serial is the only stable matcher (bus/device
      # numbers change across reboots and replugs). Get serials with:
      #   sudo nut-scanner -U
      #
      # powerValue feeds MINSUPPLIES in hosts/h005/mods/ups.nix: the sum of all
      # powerValues is used as MINSUPPLIES so that EITHER UPS going critical
      # trips the shutdown sequence (OR semantics), regardless of which one
      # actually feeds h005 itself.
      devices = {
        apc1 = {
          driver = "usbhid-ups";
          vendorId = "051D";
          productId = "0002";
          serial = "0B2507L36635";
          description = "APC Back-UPS XS 1500M (#1)";
          powerValue = 1;
        };
        apc2 = {
          driver = "usbhid-ups";
          vendorId = "051D";
          productId = "0002";
          serial = "0B2553L05396";
          description = "APC Back-UPS XS 1500M (#2)";
          powerValue = 1;
        };
      };

      # Remote hosts to shut down on critical battery
      remoteShutdownHosts = [
        {
          name = "h001";
          host = "10.12.14.10";
          user = "root";
          keyFile = "/var/lib/secrets_manager_hydrated/ups_shutdown_2026-10-22";
        }
        {
          name = "h004";
          host = "10.12.14.184";
          user = "root";
          keyFile = "/var/lib/secrets_manager_hydrated/ups_shutdown_2026-10-22";
        }
      ];
    };
  };
}
