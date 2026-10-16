# Service constants for h005 (router replacing h003; bcachefs root + impermanence).
# Bench stage: plain DHCP client, no router services yet. The router config
# (VLANs, dnsmasq, NAT, AdGuard, DDNS, NUT, speedtest) moves over from
# hosts/h003 in readme.md Phase 2/3.
{
  host = {
    name = "h005";
    overlayIp = "100.64.0.3";
    primaryUser = "luser";
    stateVersion = "26.05";
  };

  network = {
    # Physically labelled on the case.
    wanInterface = "enp1s0"; # 00:ce:39:d8:0c:17 -> modem
    trunkInterface = "enp2s0"; # 00:ce:39:d8:0c:18 -> SG3210X Tw1/0/8 (802.1Q trunk)
  };
}
