# Shared DNS records for h001 services
# Used by headscale for DNS splitting and by other hosts for /etc/hosts fallback
#
# IMPORTANT: Keep in sync with hosts/fleet.nix (h001Subdomains, hosts.h001.overlayIp, global.domain)
{
  # h001's tailscale IP
  ip = "100.64.0.13";

  # List of subdomain names that point to h001
  subdomains = [
    "jellyfin"
    "media"
    "notes"
    "chat"
    "sso-proxy"
    "n8n"
    "sec"
    "sso"
    "gist"
    "git"
    "blog"
    "etebase"
    "photos"
    "location"
    "matrix"
    "element"
    "docs"
  ];

  # Base domain
  baseDomain = "joshuabell.xyz";
}
