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
    nginxReload = "systemctl reload nginx";
  });
  # Snapshot of nginx.nix's pre-cutover stream; never derived from placement.
  # Seeded once per edge (stream-seed writes ${dir}/.seeded); dir must persist.
  snapshot = pkgs.writeText "fleet-edge-stream-seed.conf" ''
    server { listen 3032; proxy_pass ${fleet.hosts.h001.overlayIp}:3032; }
  '';
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
  seed = pkgs.writeShellScript "fleet-stream-seed" ''
    umask 022
    exec ${lib.getExe cfg.package} stream-seed --config ${receiverConfig} --snapshot ${snapshot}
  '';
in {
  environment.systemPackages = [ receive expire ];
  systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];
  system.activationScripts.fleet-stream-seed = {
    deps = [ "specialfs" ];
    text = "${seed}";
  };
  systemd.services.fleet-stream-expire-boot = {
    description = "Seed and expire runtime edge streams before nginx";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = seed;
      ExecStart = "${lib.getExe expire} --no-reload";
    };
  };
  systemd.services.fleet-stream-expire = {
    description = "Expire invalid runtime edge streams";
    serviceConfig = { Type = "oneshot"; ExecStart = lib.getExe expire; };
  };
  systemd.timers.fleet-stream-expire = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "1min"; AccuracySec = "5s"; };
  };
}
