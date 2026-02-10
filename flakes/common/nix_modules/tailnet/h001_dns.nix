# Shared DNS records for h001 services
# Used by headscale for DNS splitting and by other hosts for /etc/hosts fallback
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
  ];

  # Base domain
  baseDomain = "joshuabell.xyz";
}
