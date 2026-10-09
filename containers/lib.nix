# Shared helpers for "floating" services in containers/<app>/.
#
# Every app directory has:
#   service.nix  plain metadata (read by the parent flake and the `containers` CLI)
#   flake.nix    builds the deployable artifact as packages.<system>.default
#
# Two kinds of service:
#   kind = "nixos"   extra-container / systemd-nspawn, NixOS modules inside
#   kind = "podman"  OCI image run by a podman systemd unit
#
# Both use the same persistence model: the root filesystem is thrown away on
# every start. Only the directories listed in `persist` survive. They live on
# the host at /srv/containers/<name>/<key> and are bind-mounted with an idmap.
# With an idmap, the file owners on the host are the same numbers the
# container sees, so there is no host UID ledger. Copying the directory with
# --numeric-owner moves it to any other host.
let
  dataRoot = "/srv/containers";

  # Turn a persist attrset { key = "/path/in/container"; } into a list of
  # { host, container } pairs.
  persistList =
    service:
    map (key: {
      host = "${dataRoot}/${service.name}/${key}";
      container = service.persist.${key};
    }) (builtins.attrNames (service.persist or { }));

  # Defaults so service.nix files can stay short.
  normalize =
    service:
    {
      kind = "nixos";
      host = null;
      persist = { };
      tcpPorts = [ ];
      udpPorts = [ ];
      nginx = null;
      description = "";
    }
    // service;
in
{
  inherit dataRoot persistList normalize;

  # The extra-container `config` for a nixos-kind service. Pass it to
  # extra-container.lib.buildContainers { config = ...; }.
  #
  #   privateUsers = "pick"  nspawn picks a free 64k UID range on each start.
  #                          Every bind (including /nix) is idmapped, so the
  #                          filesystem behind /srv/containers must support
  #                          idmapped mounts (ext4, btrfs, xfs, tmpfs,
  #                          bcachefs on recent kernels; run `containers check-idmap`).
  mkNixosContainer =
    {
      service,
      config,
      specialArgs ? { },
      privateUsers ? "pick",
      privateNetwork ? false,
      extraContainerConfig ? { },
    }:
    let
      svc = normalize service;
    in
    {
      containers.${svc.name} = {
        ephemeral = true;
        autoStart = true;
        inherit privateUsers privateNetwork specialArgs;
        extraFlags = map (b: "--bind=${b.host}:${b.container}:idmap") (persistList svc);
        config =
          { lib, ... }:
          {
            imports = [ config ];
            # With the host network the guest has no CAP_NET_ADMIN on the host
            # namespace (privateUsers), so its firewall can't load. The host
            # firewall is the one that counts; ports are opened by `containers`.
            networking.firewall.enable = lib.mkIf (!privateNetwork) (lib.mkForce false);
          };
      }
      // extraContainerConfig;
    };

  # A deployable podman service. Produces a store path with:
  #   etc/systemd/system/fleet-<name>.service
  #   bin/fleet-install    links the unit into /etc/systemd-mutable/system and (re)starts it
  #   bin/fleet-uninstall  stops the unit and removes the link (data is kept)
  #
  # `podman` attrs:
  #   image       required, e.g. "docker.io/traefik/whoami:v1.10"
  #   ports       list of "hostPort:containerPort" strings (published on 127.0.0.1
  #               unless an address is given, e.g. "0.0.0.0:25565:25565")
  #   environment attrset of env vars
  #   extraArgs   list of extra `podman run` args
  #   cmd         list, the container command
  mkPodmanService =
    {
      pkgs,
      service,
    }:
    let
      svc = normalize service;
      p = svc.podman;
      unitName = "fleet-${svc.name}.service";
      lib = pkgs.lib;
      publish = map (
        port:
        let
          parts = lib.splitString ":" port;
        in
        "--publish=" + (if builtins.length parts == 2 then "127.0.0.1:${port}" else port)
      ) (p.ports or [ ]);
      volumes = map (b: "--volume=${b.host}:${b.container}:idmap") (persistList svc);
      envs = lib.mapAttrsToList (k: v: "--env=${k}=${toString v}") (p.environment or { });
      runArgs = [
        "--rm"
        "--name=${svc.name}"
        "--replace"
        "--userns=auto"
        "--sdnotify=conmon"
        "--log-driver=journald"
      ]
      ++ publish
      ++ volumes
      ++ envs
      ++ (p.extraArgs or [ ])
      ++ [ p.image ]
      ++ (p.cmd or [ ]);
      unit = pkgs.writeText unitName ''
        [Unit]
        Description=containers podman service ${svc.name}
        Wants=network-online.target
        After=network-online.target
        ${lib.concatMapStrings (b: "RequiresMountsFor=${b.host}\n") (persistList svc)}
        [Service]
        Type=notify
        NotifyAccess=all
        Restart=on-failure
        TimeoutStartSec=900
        TimeoutStopSec=120
        Environment=PATH=/run/wrappers/bin:/run/current-system/sw/bin
        ExecStart=${pkgs.podman}/bin/podman run ${lib.escapeShellArgs runArgs}
        ExecStop=${pkgs.podman}/bin/podman stop --ignore --time=60 ${svc.name}

        [Install]
        WantedBy=multi-user.target
      '';
      mutable = "/etc/systemd-mutable/system";
      install = pkgs.writeShellScript "fleet-install" ''
        set -euo pipefail
        self=$(dirname "$(dirname "$(readlink -f "$0")")")
        mkdir -p ${mutable}/multi-user.target.wants /nix/var/nix/gcroots/fleet-containers
        ln -sfn "$self" /nix/var/nix/gcroots/fleet-containers/${svc.name}
        old=$(readlink -f ${mutable}/${unitName} 2>/dev/null || true)
        ln -sfn "$self/etc/systemd/system/${unitName}" ${mutable}/${unitName}
        ln -sfn ../${unitName} ${mutable}/multi-user.target.wants/${unitName}
        systemctl daemon-reload
        if [ "$old" != "$(readlink -f ${mutable}/${unitName})" ] || ! systemctl is-active -q ${unitName}; then
          systemctl restart ${unitName}
        fi
      '';
      uninstall = pkgs.writeShellScript "fleet-uninstall" ''
        set -euo pipefail
        systemctl stop ${unitName} || true
        rm -f ${mutable}/${unitName} ${mutable}/multi-user.target.wants/${unitName} /nix/var/nix/gcroots/fleet-containers/${svc.name}
        systemctl daemon-reload
      '';
    in
    pkgs.runCommand "fleet-${svc.name}" { } ''
      install -D -m644 ${unit} $out/etc/systemd/system/${unitName}
      install -D -m755 ${install} $out/bin/fleet-install
      install -D -m755 ${uninstall} $out/bin/fleet-uninstall
    '';
}
