# Paseo execution environment on h001 (shared module: flakes/paseo).
# Private and authenticated; populate the operator-owned secret file and the
# hand-maintained provider/nono configs in /var/lib/paseo
# (flakes/paseo/README.md) before starting the container.
#
# Reachable from the tailnet only, through the vhost below. Nothing binds the
# daemon port on the host (bazarr owns :6767 there).
{
  config,
  constants,
  fleet,
  inputs,
  pkgs,
  ...
}:
let
  c = constants.services.paseo;
  net = constants.containerNetwork;
in
{
  imports = [ inputs.paseo.nixosModules.container ];

  ringofstorms.paseo = {
    enable = true;
    inherit (c)
      port
      uid
      gid
      dataDir
      projectsDir
      containerIp
      containerIp6
      ;
    inherit (net) hostAddress hostAddress6;
    secretFile = "${fleet.global.secretsDir}/paseo_agent_env_2026-09-21";
    proxy.domain = c.domain;
    # The guest reaches quad-100 (DNS) and other tailnet hosts through the
    # masquerade. LiteLLM on h001 itself (h001.net.<domain> -> the host's own
    # tailnet address) is delivered locally via the trusted ve-* interface.
    tailnet = {
      enable = true;
      domains = [
        "net.${fleet.global.domain}"
        "~${fleet.global.domain}"
      ];
    };
    ompPackage = inputs.omp-flake.inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.default;
    extraGuestModules = [
      (inputs.paseo.lib.toolsModule {
        inherit (inputs) common ros_neovim;
        hostConfig = config;
        inherit (constants.host) primaryUser;
      })
    ];
  };

  services.nginx.virtualHosts.${c.domain} = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
    extraConfig = ''
      # Tailnet-only: allow overlay network and localhost, deny everything else
      allow 100.64.0.0/10;
      allow 127.0.0.0/8;
      deny all;
    '';
    locations."/" = {
      proxyPass = "http://${c.containerIp}:${toString c.port}";
      proxyWebsockets = true;
      # Headers are set here instead: the recommended set sends `Host $host`,
      # and a second Host header cannot override it.
      recommendedProxySettings = false;
      extraConfig = ''
        # Paseo's web UI tells the browser to connect to the daemon at the
        # request's Host, which must be host:port; the daemon ignores the port
        # when matching hostnames.
        proxy_set_header Host $host:443;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # Agent sessions and terminals are long-lived, often idle WebSockets.
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
      '';
    };
  };
}
