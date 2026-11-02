# Runtime public TCP streams, reconciled by h005 over the vhost push key.
{ config, lib, pkgs, fleet, ... }:
let
  cfg = config.fleet.edgeVhost;
  dir = "/var/lib/fleet-edge-streams";
  nginx = config.services.nginx;
  ports = (import ../../../containers/lib.nix).edgeStreamPorts ../../../containers;
  hosts = lib.mapAttrs (_: h: h.overlayIp) (lib.filterAttrs (_: h: (h.overlayIp or null) != null) fleet.hosts);
  receiverConfig = pkgs.writeText "fleet-edge-stream.json" (builtins.toJSON {
    inherit dir hosts ports;
    nginxTest = ''"${nginx.package}/bin/nginx" -t -c "$(systemctl show -p ExecStart --value nginx | grep -o -- '-c [^ ;]*' | head -1 | cut -d' ' -f2)"'';
    # Blocking, and its exit status is not enough: ExecReload is nginx -t
    # plus kill -HUP, and the master can still fail to load the config (e.g.
    # a taken port). The receiver clears .reload-pending only once
    # nginxMainPid's workers have been replaced (internal/nginxgen). It runs
    # after the dir flock is released (edgestream settle), so a reload queued
    # behind fleet-stream-expire-boot (Before=nginx, takes the same flock)
    # cannot deadlock. Never --no-block (LoadConfig refuses it).
    nginxReload = "systemctl reload nginx";
    nginxMainPid = "systemctl show -p MainPID --value nginx";
  });
  path = lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
  receive = pkgs.writeShellScriptBin "fleet-stream-receive" ''
    export PATH=${path}
    umask 022
    exec ${lib.getExe cfg.package} stream-receive --config ${receiverConfig}
  '';
  expire = pkgs.writeShellScriptBin "fleet-stream-expire" ''
    export PATH=${path}
    exec ${lib.getExe cfg.package} stream-expire --config ${receiverConfig} "$@"
  '';
in {
  environment.systemPackages = [ receive expire ];
  systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];
  systemd.services.fleet-stream-expire-boot = {
    description = "Expire runtime edge streams before nginx";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe expire} --no-reload";
    };
  };
  systemd.services.fleet-stream-expire = {
    description = "Expire invalid runtime edge streams";
    after = [ "fleet-stream-expire-boot.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = lib.getExe expire; };
  };
  systemd.timers.fleet-stream-expire = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "1min"; AccuracySec = "5s"; };
  };
}
