# Receiver for runtime public vhosts pushed by h005's fleet-edge-overrides
# (containers/ROUTING-PLAN.md §8 step 7, "Public expose design" item 3).
#
# h005 runs the vhost or stream receiver over root SSH with one dedicated
# key. The forced dispatcher selects streams only for the exact command;
# every other command reaches this vhost receiver. The request is JSON on stdin:
# (fleet-edge `vhost-receive`, internal/edgevhost) validates it against the
# build-time config below and renders the server block itself, proxying to
# the service host's edge listener (<overlayIp>:8443) with the pushed
# wildcard. Every change is `nginx -t`-checked and rolled back on failure.
#
# Files live in ${dir}, which is NOT persisted: a reboot closes every
# runtime vhost (h005's sweep re-pushes live rows). Each file carries its
# own deadline; fleet-vhost-expire removes expired files every minute and
# at boot before nginx, so o002 closes even if h005 is gone.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  cfg = config.fleet.edgeVhost;
  domain = fleet.global.domain;
  dir = "/var/lib/fleet-edge-vhosts";
  nginxCfg = config.services.nginx;
  limitZone = "fleet_edge_rt";

  hosts = lib.mapAttrs (_: h: h.overlayIp) (
    lib.filterAttrs (_: h: (h.overlayIp or null) != null) fleet.hosts
  );
  # Names this edge already serves from its own config: never overridable.
  reserved = lib.unique (
    lib.concatLists (lib.mapAttrsToList (n: v: [ n ] ++ (v.serverAliases or [ ])) nginxCfg.virtualHosts)
  );

  receiverConfig = pkgs.writeText "fleet-edge-vhost.json" (
    builtins.toJSON {
      inherit
        domain
        dir
        hosts
        reserved
        limitZone
        ;
      certDir = config.fleet.wildcardCertDir;
      # Same -c trick as wildcard-cert-receiver.nix: test what nginx runs.
      nginxTest = ''"${nginxCfg.package}/bin/nginx" -t -c "$(systemctl show -p ExecStart --value nginx | grep -o -- '-c [^ ;]*' | head -1 | cut -d' ' -f2)"'';
      nginxReload = "systemctl reload nginx";
    }
  );

  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.systemd
  ];

  receive = pkgs.writeShellScriptBin "fleet-vhost-receive" ''
    export PATH=${path}
    umask 022
    exec ${lib.getExe cfg.package} vhost-receive --config ${receiverConfig}
  '';
  expire = pkgs.writeShellScriptBin "fleet-vhost-expire" ''
    export PATH=${path}
    exec ${lib.getExe cfg.package} vhost-expire --config ${receiverConfig} "$@"
  '';
  dispatch = pkgs.writeShellScriptBin "fleet-edge-receive" ''
    if [ "''${SSH_ORIGINAL_COMMAND:-}" = fleet-stream-receive ]; then
      exec /run/current-system/sw/bin/fleet-stream-receive
    fi
    exec ${lib.getExe receive}
  '';
in
{
  options.fleet.edgeVhost = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "fleet-edge package (provides vhost-receive / vhost-expire).";
    };
    pushPubKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = fleet.global.edgeVhostPushPubKey or null;
      description = ''
        Dedicated SSH public key for h005's fleet-edge-overrides, restricted
        to fleet-edge-receive. Not the wildcard cert key. null = no key line
        (the receiver is installed but unreachable).
      '';
    };
  };

  config = {
    environment.systemPackages = [
      receive
      expire
      dispatch
    ];
    systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];

    services.nginx.appendHttpConfig = ''
      # Runtime public vhosts (cnt expose --exposure public, hosts/_shared_assets/utilities/edge-vhost-receiver.nix).
      limit_req_zone $binary_remote_addr zone=${limitZone}:10m rate=20r/s;
      include ${dir}/*.conf;
    '';

    users.users.root.openssh.authorizedKeys.keys =
      lib.optional (cfg.pushPubKey != null)
        ''command="/run/current-system/sw/bin/fleet-edge-receive",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ${cfg.pushPubKey}'';

    # Boot: drop expired (or unparseable) files before nginx reads them.
    systemd.services.fleet-vhost-expire-boot = {
      description = "Drop expired runtime edge vhosts before nginx";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe expire} --no-reload";
      };
    };
    systemd.services.fleet-vhost-expire = {
      description = "Drop expired runtime edge vhosts";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe expire;
      };
    };
    systemd.timers.fleet-vhost-expire = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        AccuracySec = "5s";
      };
    };
  };
}
