{
  config,
  pkgs,
  lib,
  constants,
  ...
}:
let
  ups = constants.services.ups;

  # Remote hosts to shut down before this machine, in order.
  # Each entry specifies the SSH connection details explicitly so the
  # shutdown script works as root without depending on any user's SSH config.
  remoteHosts = ups.remoteShutdownHosts;

  shutdownScript = pkgs.writeShellScript "ups-shutdown" ''
    export PATH="${lib.makeBinPath (with pkgs; [ openssh coreutils systemd ])}:$PATH"

    log() {
      echo "$(date '+%Y-%m-%d %H:%M:%S') [ups-shutdown] $1"
    }

    log "UPS shutdown sequence initiated"

    # Shut down remote hosts first (in parallel, then wait)
    ${lib.concatMapStringsSep "\n" (remote: ''
      (
        log "Shutting down ${remote.name} (${remote.host})..."
        ssh -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/root/.ssh/known_hosts \
            -i ${remote.keyFile} \
            ${remote.user}@${remote.host} \
            "sudo /run/current-system/sw/bin/shutdown -h now 'UPS battery critical'" \
          && log "${remote.name} shutdown command sent" \
          || log "${remote.name} shutdown failed (may already be down)"
      ) &
    '') remoteHosts}

    # Wait for all remote shutdown commands to complete (or timeout)
    wait

    # Brief pause for remote hosts to begin shutdown
    sleep 5

    log "Shutting down local system (h003)"
    /run/current-system/sw/bin/shutdown -h now "UPS battery critical"
  '';

  notifyScript = pkgs.writeShellScript "ups-notify" ''
    export PATH="${lib.makeBinPath (with pkgs; [ coreutils ])}:$PATH"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ups-notify] $NOTIFYTYPE: $UPSNAME - $*"
  '';

  # Password file path for NUT internal auth between upsd and upsmon.
  # This is local-only auth, the actual value doesn't matter much.
  upsmonPasswordFile = "/etc/nut/upsmon.password";
in
{
  # NUT - Network UPS Tools
  power.ups = {
    enable = true;
    mode = "standalone";

    ups.apc = {
      driver = ups.driver;
      port = "auto";
      description = ups.description;
      directives = [
        "vendorid = ${ups.vendorId}"
        "productid = ${ups.productId}"
        "pollinterv = 15"
      ];
    };

    users.upsmon_local = {
      upsmon = "primary";
      passwordFile = upsmonPasswordFile;
    };

    upsmon = {
      monitor.apc = {
        system = "apc@localhost";
        powerValue = 1;
        user = "upsmon_local";
        passwordFile = upsmonPasswordFile;
        type = "primary";
      };

      settings = {
        MINSUPPLIES = 1;
        SHUTDOWNCMD = "${shutdownScript}";
        NOTIFYCMD = "${notifyScript}";
        POLLFREQ = 5;
        POLLFREQALERT = 2;
        HOSTSYNC = 15;
        DEADTIME = 25;
        FINALDELAY = 5;

        NOTIFYFLAG = [
          [ "ONLINE" "SYSLOG+EXEC" ]
          [ "ONBATT" "SYSLOG+EXEC" ]
          [ "LOWBATT" "SYSLOG+EXEC" ]
          [ "FSD" "SYSLOG+EXEC" ]
          [ "COMMOK" "SYSLOG+EXEC" ]
          [ "COMMBAD" "SYSLOG+EXEC" ]
          [ "SHUTDOWN" "SYSLOG+EXEC" ]
          [ "REPLBATT" "SYSLOG+EXEC" ]
          [ "NOCOMM" "SYSLOG+EXEC" ]
        ];
      };
    };
  };

  # Generate a stable password file for NUT internal auth.
  # This password only secures local upsd<->upsmon communication.
  systemd.tmpfiles.rules = [
    "f ${upsmonPasswordFile} 0640 root root - upsmon_local_password"
  ];

  # Ensure root SSH directory exists for the shutdown script's known_hosts
  systemd.services."ups-ssh-setup" = {
    description = "Prepare root SSH directory for UPS shutdown script";
    wantedBy = [ "multi-user.target" ];
    before = [ "upsmon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh

      # Pre-populate known_hosts so shutdown doesn't fail on first run
      ${lib.concatMapStringsSep "\n" (remote: ''
        ${pkgs.openssh}/bin/ssh-keyscan -T 5 ${remote.host} >> /root/.ssh/known_hosts 2>/dev/null || true
      '') remoteHosts}

      # Deduplicate
      if [ -f /root/.ssh/known_hosts ]; then
        sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
      fi
    '';
  };

  # Ensure NUT can access the USB device
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="${lib.toLower ups.vendorId}", ATTR{idProduct}=="${lib.toLower ups.productId}", MODE="0660", GROUP="nut"
  '';
}
