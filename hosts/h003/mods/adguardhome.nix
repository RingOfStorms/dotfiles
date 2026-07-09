# AdGuard Home — FULLY declarative config.
#
# The entire runtime config lives in this repo. `mutableSettings = false` means
# on every start the module does `cp --force` of the Nix-generated config over
# /var/lib/AdGuardHome/AdGuardHome.yaml — so the web UI is effectively
# read-only: any change made in the UI is REVERTED on the next service restart /
# rebuild. Edit this file to change AdGuard.
#
# ADMIN PASSWORD (users:) — the bcrypt hash IS committed here in plaintext.
# This is a DELIBERATE, accepted decision for THIS service because:
#   - AdGuard's admin UI is reachable only from the internal LAN (firewalled;
#     not exposed to the internet or, by policy, treated as LAN-only), and
#   - the password is strong + random + unique (not reused anywhere), so even
#     if the bcrypt hash were cracked offline it unlocks nothing beyond this
#     LAN-only admin panel.
# bcrypt is salted + adaptive, so the hash is not directly reversible; the only
# risk is offline brute force, mitigated by the password's entropy. Do NOT copy
# this pattern for internet-exposed services or shared/weak passwords — use
# secrets-bao for those.
#
# `http.address` is injected automatically by the NixOS module from
# `host`/`port` below — do not put it in `settings`.
#
# schema_version is supplied by the module from the adguardhome package
# (nixpkgs 26.05 ships 0.107.77 / schema 34, matching the exported config).
{ constants, ... }:
let
  dns = constants.network.dnsUpstreams;
in
{
  config = {
    services.adguardhome = {
      enable = true;
      allowDHCP = false; # DHCP is served by dnsmasq (see networking.nix); AdGuard DHCP is off.
      openFirewall = false;
      mutableSettings = false; # FULLY declarative: Nix config overwrites the on-disk file every start.

      host = "0.0.0.0";
      port = 3000; # admin UI (http.address = 0.0.0.0:3000)

      settings = {
        # Admin web UI login. bcrypt hash committed intentionally — see the
        # header comment (LAN-only + strong unique password). Generate a new
        # hash with:  htpasswd -B -n -b <user> <password>   (take the part
        # after the first ':'), or `mkpasswd -m bcrypt`.
        users = [
          {
            name = "opidsjhpoidjsf";
            password = "$2a$10$CvE8RfKNxrwxZjkltBoi2OJZCiYPnN2AiEsSfdX8MMkAxH8VGk9ta";
          }
        ];

        http = {
          pprof = {
            port = 6060;
            enabled = false;
          };
          session_ttl = "30d";
        };

        auth_attempts = 5;
        block_auth_min = 15;
        http_proxy = "";
        language = "";
        theme = "auto";

        dns = {
          bind_hosts = [ "0.0.0.0" ];
          port = 53;
          anonymize_client_ip = false;
          ratelimit = 0;
          ratelimit_subnet_len_ipv4 = 24;
          ratelimit_subnet_len_ipv6 = 56;
          ratelimit_whitelist = [ ];
          refuse_any = true;

          # Upstreams. The ENTIRE joshuabell.xyz zone is routed to the local
          # dnsmasq (127.0.0.1:9053), which is the single authoritative source
          # for all local records under that domain (see networking.nix +
          # _constants.nix:localDnsRecords). Everything else uses the shared
          # upstream set (plain IPs + encrypted), from _constants.nix so AdGuard
          # and dnsmasq stay in sync.
          upstream_dns = [
            "# Local zone -> dnsmasq (authoritative for all *.joshuabell.xyz)"
            "[/joshuabell.xyz/]127.0.0.1:9053"
            "# Shared upstreams (plain IP, also used by dnsmasq fallthrough)"
          ]
          ++ dns.plainIp
          ++ [ "# Encrypted upstreams (AdGuard only)" ]
          ++ dns.encrypted;
          upstream_dns_file = "";
          bootstrap_dns = [
            "9.9.9.10"
            "149.112.112.10"
            "2620:fe::10"
            "2620:fe::fe:10"
          ];
          fallback_dns = [ ];
          upstream_mode = "parallel";
          fastest_timeout = "1s";
          allowed_clients = [ ];
          disallowed_clients = [ ];
          blocked_hosts = [
            "version.bind"
            "id.server"
            "hostname.bind"
          ];
          trusted_proxies = [
            "127.0.0.0/8"
            "::1/128"
          ];
          cache_enabled = true;
          cache_size = 4194304;
          cache_ttl_min = 0;
          cache_ttl_max = 0;
          cache_optimistic = false;
          cache_optimistic_answer_ttl = "30s";
          cache_optimistic_max_age = "12h";
          bogus_nxdomain = [ ];
          aaaa_disabled = false;
          enable_dnssec = false;
          edns_client_subnet = {
            custom_ip = "";
            enabled = false;
            use_custom = false;
          };
          max_goroutines = 300;
          handle_ddr = true;
          ipset = [ ];
          ipset_file = "";
          bootstrap_prefer_ipv6 = false;
          upstream_timeout = "10s";
          private_networks = [ ];
          use_private_ptr_resolvers = true;
          local_ptr_upstreams = [ "localhost:9053" ];
          use_dns64 = false;
          dns64_prefixes = [ ];
          serve_http3 = false;
          use_http3_upstreams = false;
          serve_plain_dns = true;
          hostsfile_enabled = true;
          pending_requests.enabled = true;
        };

        tls = {
          enabled = false;
          server_name = "";
          force_https = false;
          port_https = 443;
          port_dns_over_tls = 853;
          port_dns_over_quic = 853;
          port_dnscrypt = 0;
          dnscrypt_config_file = "";
          certificate_chain = "";
          private_key = "";
          certificate_path = "";
          private_key_path = "";
          strict_sni_check = false;
        };

        querylog = {
          dir_path = "";
          ignored = [ ];
          interval = "90d";
          size_memory = 1000;
          enabled = true;
          ignored_enabled = false;
          file_enabled = true;
        };

        statistics = {
          dir_path = "";
          ignored = [ ];
          interval = "1d";
          enabled = true;
          ignored_enabled = false;
        };

        # Blocklists / filters. Declared here → Nix is authoritative (the whole
        # list is replaced on merge). Add/remove filters by editing this list.
        filters = [
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
            name = "AdGuard DNS filter";
            id = 1;
          }
          {
            enabled = false;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
            name = "AdAway Default Blocklist";
            id = 2;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt";
            name = "1Hosts (Lite)";
            id = 1727639810;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt";
            name = "AdGuard DNS Popup Hosts filter";
            id = 1727639811;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_38.txt";
            name = "1Hosts (mini)";
            id = 1727639812;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt";
            name = "Dan Pollock's List";
            id = 1727639813;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_53.txt";
            name = "AWAvenue Ads Rule";
            id = 1727639814;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_34.txt";
            name = "HaGeZi's Normal Blocklist";
            id = 1727639815;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_48.txt";
            name = "HaGeZi's Pro Blocklist";
            id = 1727639816;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt";
            name = "HaGeZi's Pro++ Blocklist";
            id = 1727639817;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt";
            name = "HaGeZi's Ultimate Blocklist";
            id = 1727639818;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_5.txt";
            name = "OISD Blocklist Small";
            id = 1727639819;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt";
            name = "Malicious URL Blocklist (URLHaus)";
            id = 1727639820;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt";
            name = "OISD Blocklist Big";
            id = 1727639821;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt";
            name = "uBlock₀ filters – Badware risks";
            id = 1727639822;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt";
            name = "Peter Lowe's Blocklist";
            id = 1727639823;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt";
            name = "The Big List of Hacked Malware Web Sites";
            id = 1727639824;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_33.txt";
            name = "Steven Black's List";
            id = 1727639825;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_31.txt";
            name = "Stalkerware Indicators List";
            id = 1727639826;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_45.txt";
            name = "HaGeZi's Allowlist Referral";
            id = 1727639827;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_42.txt";
            name = "ShadowWhisperer's Malware List";
            id = 1727639828;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_7.txt";
            name = "Perflyst and Dandelion Sprout's Smart-TV Blocklist";
            id = 1727639829;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_10.txt";
            name = "Scam Blocklist by DurableNapkin";
            id = 1727639830;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt";
            name = "Phishing URL Blocklist (PhishTank and OpenPhish)";
            id = 1727639831;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_18.txt";
            name = "Phishing Army";
            id = 1727639832;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_12.txt";
            name = "Dandelion Sprout's Anti-Malware List";
            id = 1727639833;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_8.txt";
            name = "NoCoin Filter List";
            id = 1727639834;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_44.txt";
            name = "HaGeZi's Threat Intelligence Feeds";
            id = 1727639836;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_54.txt";
            name = "HaGeZi's DynDNS Blocklist";
            id = 1727639837;
          }
          {
            enabled = true;
            url = "https://gist.joshuabell.xyz/ringofstorms/cc9a16c56fbb4a8fb1ec83cb59d68fe8/raw/HEAD/adguard-custom-blocklist.txt";
            name = "RingOfStorms list custom";
            id = 1727639841;
          }
        ];
        whitelist_filters = [ ];

        # Custom allow/block rules. Nix authoritative.
        user_rules = [
          "@@||*^$client=ellawork"
          "# ALLOWED"
          "@@||instagram.ford4-1.fna.fbcdn.net^$important"
          "@@||zoom.us^$important"
          "@@||logfiles.zoom.us^$important"
          "@@||arc.msn.com^$important"
          "@@||graph.facebook.com^$important"
          "@@||web.facebook.com^$important"
          "@@||b-graph.facebook.com^$important"
          "@@||e.mk.virginvoyages.com^$important"
          "# BLOCKED"
          "||signaler-pa.clients6.google.com^$important"
          "||tiktokv.com^$important"
          "||tiktokcdn.com^$important"
          "||www.netgear.com^$important"
          "||connectivity-check.ubuntu.com^$important"
          "||chi-kaspersky10.chicago.mintel.ad^$important"
          "@@||bazzite.hunterraven.com^$important"
          "@@||*yahoo*^$client='10.12.14.159'"
          "@@||*yahoo*^$client='10.12.14.110'"
          ""
        ];

        dhcp.enabled = false; # dnsmasq owns DHCP

        filtering = {
          blocking_ipv4 = "";
          blocking_ipv6 = "";
          blocked_services = {
            schedule.time_zone = "UTC";
            ids = [ ];
          };
          protection_disabled_until = null;
          safe_search = {
            enabled = false;
            bing = true;
            duckduckgo = true;
            ecosia = true;
            google = true;
            pixabay = true;
            yandex = true;
            youtube = true;
          };
          blocking_mode = "default";
          parental_block_host = "family-block.dns.adguard.com";
          safebrowsing_block_host = "standard-block.dns.adguard.com";
          rewrites = [ ];
          safebrowsing_cache_size = 1048576;
          safesearch_cache_size = 1048576;
          parental_cache_size = 1048576;
          cache_time = 30;
          filters_update_interval = 24;
          blocked_response_ttl = 10;
          filtering_enabled = true;
          rewrites_enabled = true;
          parental_enabled = false;
          safebrowsing_enabled = true;
          protection_enabled = true;
        };

        # Per-client rules (the per-device settings). Nix authoritative.
        clients = {
          runtime_sources = {
            whois = true;
            arp = true;
            rdns = true;
            dhcp = true;
            hosts = true;
          };
          persistent = [
            {
              name = "ellawork";
              ids = [
                "10.12.14.122"
                "10.12.14.132"
              ];
              tags = [ ];
              upstreams = [ ];
              uid = "019a27ac-dda3-70de-8481-976980da8f37";
              upstreams_cache_size = 0;
              upstreams_cache_enabled = false;
              use_global_settings = false;
              filtering_enabled = false;
              parental_enabled = false;
              safebrowsing_enabled = false;
              use_global_blocked_services = true;
              ignore_querylog = false;
              ignore_statistics = false;
              safe_search = {
                enabled = false;
                bing = true;
                duckduckgo = true;
                ecosia = true;
                google = true;
                pixabay = true;
                yandex = true;
                youtube = true;
              };
              blocked_services = {
                schedule.time_zone = "UTC";
                ids = [ ];
              };
            }
          ];
        };

        log = {
          enabled = true;
          file = "";
          max_backups = 0;
          max_size = 100;
          max_age = 3;
          compress = false;
          local_time = false;
          verbose = false;
        };

        os = {
          group = "";
          user = "";
          rlimit_nofile = 0;
        };
      };
    };

    networking.firewall.interfaces.vlan20.allowedTCPPorts = [
      53 # DNS
      68 # DHCP
      5543 # DNSCrypt
      3000 # Initial installation
      80 # admin panel
      443 # admin panel
      853 # DNS over tls
      # 6060 # Debugging profile
    ];
    networking.firewall.interfaces.vlan20.allowedUDPPorts = [
      53 # DNS
      # 67 # DHCP
      # 68 # DHCP
      443 # Admin panel/https dns over https
      853 # DNS over quic
      5443 # DNSCrypt
    ];
  };
}
