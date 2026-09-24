{ constants, fleet, inputs, lib, pkgs, ... }:
let
  domain = fleet.global.domain;
  overlayIp = constants.host.overlayIp;
  upstreamPort = constants.services.paseo.port;
  certName = domain;
  denyAddresses = [ fleet.hosts.o002.overlayIp fleet.hosts.joe.overlayIp fleet.hosts.gp3.overlayIp ];
  denyRules = lib.concatMapStringsSep "\n" (ip: "deny ${ip};") denyAddresses;
  rejectDefault = {
    default = true;
    rejectSSL = true;
    listen = [ { addr = overlayIp; port = 443; ssl = true; } ];
    locations."/" = { return = "444"; };
  };
in
{


  security.acme = {
    acceptTerms = true;
    defaults.email = fleet.global.acmeEmail;
    certs.${certName} = {
      domain = certName;
      extraDomainNames = [ "*.${domain}" ];
      dnsProvider = "bunny";
      group = "nginx";
    };
  };

  services.paseoBareMetal = {
    enable = true;
    user = constants.host.primaryUser;
    group = "users";
    home = "/home/josh";
    dataDir = "/home/josh/.paseo";
    projects = [ "/home/josh/projects" "/home/josh/other" ];
    catalogWorkdir = "/home/josh/projects";
    uid = 1000;
    worktreesDir = "/home/josh/.paseo/worktrees";
    port = upstreamPort;
    listenAddress = "0.0.0.0";
    extraHostnames = [ overlayIp "${overlayIp}:${toString upstreamPort}" ];
    environmentFile = "${fleet.global.secretsDir}/paseo_agent_env_2026-09-21";
    proxy.domain = "paseo.${domain}";
    opencodePackage = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.opencode;
    ompPackage = inputs.omp-flake.inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ upstreamPort ];

  systemd.services.nginx = {
    wants = [ "network-online.target" "tailscaled-autoconnect.service" ];
    after = [ "network-online.target" "tailscaled-autoconnect.service" ];
    serviceConfig.IPFreeBind = true;
  };

  services.nginx.virtualHosts = {
    "paseo.${domain}" = {
      useACMEHost = certName;
      onlySSL = true;
      listen = [ { addr = overlayIp; port = 443; ssl = true; } ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString upstreamPort}";
        proxyWebsockets = true;
        recommendedProxySettings = false;
        extraConfig = ''
          ${denyRules}
          allow 100.64.0.0/10;
          deny all;
          proxy_set_header Host $host:443;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header X-Forwarded-Proto https;
          proxy_read_timeout 86400s;
          proxy_send_timeout 86400s;
          proxy_buffering off;
        '';
      };
    };
    "_" = rejectDefault;
  };
}
