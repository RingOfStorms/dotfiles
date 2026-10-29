# tmux-agents-mobile — the phone UI for tmux agent panes
# (flakes/tmux-agents-mobile, `services.tmux-agents-mobile`).
#
# Runs on lio as the primary user's systemd *user* service (it has to be the
# same account that owns the tmux server), behind the host's own nginx.
#
# Exposure is tailnet-only by construction, with no container route and no
# public DNS:
#   * nginx serves https://tmux.joshuabell.xyz from the wildcard cert h005
#     pushes to lio (containers/host-module.nix imports the receiver), and
#     redirects :80 to it;
#   * the firewall opens :80 and :443 on tailscale0 and nowhere else;
#   * h005's tailnet dnsmasq answers tmux.joshuabell.xyz with lio's overlay IP
#     (hosts/h005/dns-records.nix, handTailnet), and no other resolver knows it.
{ config, constants, fleet, ... }:
let
  domain = fleet.global.domain;
  hostname = "tmux.${domain}";
  port = 8099;
in
{
  services.tmux-agents-mobile = {
    enable = true;
    user = constants.host.primaryUser;
    listen = "127.0.0.1:${toString port}";
    healthListen = "127.0.0.1:${toString (port - 1)}";
    zitadel = {
      issuer = "https://sso.${domain}";
      # Zitadel PKCE app "tmux-agents-mobile"; the redirect URI registered with
      # it is https://tmux.joshuabell.xyz/auth/callback (derived from the
      # request's Host and X-Forwarded-Proto, so no explicit value here).
      clientId = "397271224117431554";
      # The project's resource ID: used for the `aud` scope and the roles claim.
      projectId = "397271027891047682";
    };
  };

  # fleet.wildcardTls brings the pushed cert plus forceSSL, so :80 redirects.
  # If the certificate is not on lio yet, nginx -t fails and the switch is
  # refused (the running generation keeps serving) rather than breaking nginx;
  # h005 pushes on every issue/renew plus a daily retry. Check with:
  #   sudo ls -l /var/lib/fleet-cert/joshuabell.xyz/current/
  services.nginx.virtualHosts.${hostname} = config.fleet.wildcardTls // {
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      # nginx already sends Host / X-Forwarded-* (nginx-recommended headers in
      # /etc/nginx/nginx.conf); these are the streaming bits.
      extraConfig = ''
        proxy_http_version 1.1;
        # Server-sent events: the app also sets X-Accel-Buffering: no, this is
        # belt and braces for a proxy that does not honour it.
        proxy_buffering off;
        proxy_read_timeout 1h;
      '';
    };
  };

  # lio trusts no tailscale0 traffic by default (hosts/lio/firewall.nix). These
  # are the only ports this service needs, and neither is opened on the LAN.
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" tcp dport { 80, 443 } accept comment "tmux-agents-mobile (tailnet only)"
  '';
}
