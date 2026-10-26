# Receiver for `fleet share` (containers/FLOWS-AUDIT.md §(c), "Local
# temporary sharing via *.share.joshuabell.xyz"). A laptop opens a
# restricted SSH session as the `share` user (keys from
# `fleet.global.shareKeys`); sshd's `Match User share` block forces this
# one command (`fleet-share-serve`, fleet-edge `internal/shareserve`).
#
# `share` is kept fully unprivileged: it never touches nginx. It only
# writes a small JSON request into `requestsDir`, the ONLY directory it
# can write to (0700 share:share) -- `share` does not own any ancestor of
# `confDir` or `statusDir`, so it can never rename/replace those
# directories or plant a symlink where root expects to read or write.
# `fleet-share-apply` (root, triggered by a `.path` unit watching
# requestsDir) never trusts a request file past an O_NOFOLLOW open plus an
# fstat check (regular file, owned by the share uid, size-capped); it
# re-validates the name/port from scratch and renders the vhost itself
# into `confDir` (root-owned; nginx's `include` only reads from there),
# then nginx -t's and reloads with the real, unmodified `-c`. Status files
# live in root-owned `statusDir`, which `share` only ever reads.
# `fleet-share-sweep` (timer, root) separately drops any confDir entry
# whose port isn't currently a live listener, plus stale requests/statuses.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  domain = "share.${fleet.global.domain}";
  requestsDir = "/run/fleet-share/requests";
  confDir = "/run/fleet-share/conf";
  statusDir = "/run/fleet-share/status";
  limitZone = "fleet_share_rt";
  # Pushed by wildcard-cert.nix / received via wildcard-cert-receiver.nix's
  # fleet.wildcardExtraCertNames (o002 flake.nix lists this domain).
  certDir = "/var/lib/fleet-cert/${domain}/current";
  nginxCfg = config.services.nginx;

  receiverConfig = pkgs.writeText "fleet-share.json" (
    builtins.toJSON {
      inherit
        domain
        requestsDir
        confDir
        statusDir
        limitZone
        certDir
        ;
      shareUser = "share";
      # Same -c trick as wildcard-cert-receiver.nix / edge-vhost-receiver.nix:
      # test what nginx actually runs. Run as root (fleet-share-apply), so no
      # pidfile rewrite is needed.
      nginxTest = ''"${nginxCfg.package}/bin/nginx" -t -c "$(systemctl show -p ExecStart --value nginx | grep -o -- '-c [^ ;]*' | head -1 | cut -d' ' -f2)"'';
      nginxReload = "systemctl reload nginx";
      maxFor = 24 * 60 * 60;
    }
  );

  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.systemd
  ];

  serve = pkgs.writeShellScriptBin "fleet-share-serve" ''
    export PATH=${path}
    umask 077
    exec ${lib.getExe config.fleet.shareVhost.package} share-serve --config ${receiverConfig}
  '';
  apply = pkgs.writeShellScriptBin "fleet-share-apply" ''
    export PATH=${path}
    umask 022
    exec ${lib.getExe config.fleet.shareVhost.package} share-apply --config ${receiverConfig}
  '';
  sweep = pkgs.writeShellScriptBin "fleet-share-sweep" ''
    export PATH=${path}
    exec ${lib.getExe config.fleet.shareVhost.package} share-sweep --config ${receiverConfig}
  '';
in
{
  options.fleet.shareVhost = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "fleet-edge package (provides share-serve / share-apply / share-sweep).";
    };
  };

  config = {
    environment.systemPackages = [
      serve
      apply
      sweep
    ];
    systemd.tmpfiles.rules = [
      # Nothing root writes may live under a share-writable directory:
      # requestsDir (0700 share:share) is the ONLY place `share` can
      # write, and it is a leaf -- root never creates anything inside it,
      # only reads (O_NOFOLLOW+fstat) and unlinks (unlinkat) from it.
      # confDir/statusDir are root-owned and share has no write access to
      # either them or their parent, so it can never rename/replace them.
      "d /run/fleet-share 0755 root root -"
      "d ${requestsDir} 0700 share share -"
      "d ${confDir} 0755 root root -"
      "d ${statusDir} 0755 root root -"
    ];

    services.nginx.appendHttpConfig = ''
      # *.share runtime vhosts (fleet share, hosts/_shared_assets/utilities/share-receiver.nix).
      limit_req_zone $binary_remote_addr zone=${limitZone}:10m rate=20r/s;
      include ${confDir}/*.conf;
    '';
    # Catch-all for *.share names with no live share (wildcard server_name,
    # NOT default_server: nginx.nix already owns the :443/:80 default vhost
    # (reject-handshake / 444), and two default_server blocks on the same
    # listen refuse nginx -t / nginx won't start. nginx prefers an exact
    # server_name match over a wildcard, so a live share's runtime conf
    # (included above, exact name) still wins over this one.
    services.nginx.virtualHosts."share-default" = {
      serverName = "*.${domain}";
      onlySSL = true;
      sslCertificate = "${certDir}/fullchain.pem";
      sslCertificateKey = "${certDir}/key.pem";
      locations."/".return = "444";
    };
    services.nginx.virtualHosts."share-default-http" = {
      serverName = "*.${domain}";
      locations."/".return = "444";
    };

    users.users.share = {
      isSystemUser = true;
      group = "share";
      # Fully unprivileged: no nginx group membership, no cert/log access.
      # No shell needed: ForceCommand below always wins, but a real shell
      # keeps `sh -c` happy inside the forced command itself.
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = fleet.global.shareKeys or [ ];
    };
    users.groups.share = { };

    services.openssh.extraConfig = ''
      Match User share
        ForceCommand ${lib.getExe serve}
        AllowTcpForwarding remote
        AllowStreamLocalForwarding no
        PermitOpen none
        PermitListen 127.0.0.1:*
        X11Forwarding no
        AllowAgentForwarding no
        PermitTTY no
    '';

    # Root oneshot: renders/reloads/revalidates, triggered whenever `dir`
    # gets a new *.new or *.remove request (see share.go's writeFileAtomic).
    systemd.services.fleet-share-apply = {
      description = "Render/reload *.share runtime vhosts from pending requests";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe apply;
      };
    };
    systemd.paths.fleet-share-apply = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = requestsDir;
        PathExistsGlob = "${requestsDir}/*.new";
        Unit = "fleet-share-apply.service";
      };
    };

    systemd.services.fleet-share-sweep = {
      description = "Remove stale *.share runtime vhosts left by a crashed session";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe sweep;
      };
    };
    systemd.timers.fleet-share-sweep = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        AccuracySec = "5s";
      };
    };
  };
}
