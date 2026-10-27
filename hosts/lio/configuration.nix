{
  pkgs,
  lib,
  constants,
  fleet,
  ...
}:
let
  nixServe = constants.services.nixServe;
  fleetLib = import ../../containers/lib.nix;
  sshHighTrustIps = fleetLib.firewallHighTrustIps {
    hosts = fleet.hosts;
    exclude = [
      "o002"
      "lio"
    ];
  };
  nixBuildReceive = pkgs.writeShellApplication {
    name = "fleet-nix-build-receive";
    text = ''
      set -f
      cmd="''${SSH_ORIGINAL_COMMAND:-}"
      case "$cmd" in
        "nix-daemon --stdio")
          exec /run/current-system/sw/bin/nix-daemon --stdio
          ;;
        "nix-store --serve")
          exec /run/current-system/sw/bin/nix-store --serve
          ;;
        "nix-store --serve --write")
          exec /run/current-system/sw/bin/nix-store --serve --write
          ;;
        *)
          echo "fleet-nix-build-receive: command rejected" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  # Close port 22 on the global allow-list set by hardening.nix and re-open
  # it only on tailscale0 (high-trust overlay IPs only, ROUTING-PLAN §8 step
  # 2; o002 excluded) + the LAN CIDR (kept: lio is a workstation reached
  # from the LAN too). Using nftables source-address filtering (rather than
  # per-interface) means it keeps working regardless of whether the LAN is
  # reached via wired or Wi-Fi.
  #
  # `allowedTCPPorts` has list-merge semantics across modules, and `mkForce`
  # replaces *all* contributions — so any port this host should open
  # globally must be re-listed here (currently none).
  #
  # No sshGuardAssertion here: lio always excludes itself from its own
  # high-trust set (it reaches itself locally, never over tailscale0), so
  # the "contains lio's overlayIp" check doesn't apply to this file. Every
  # *other* host's firewall.nix carries the assertion instead.
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshHighTrustIps} } tcp dport 22 accept comment "generated: ssh, high-trust tailnet only (ROUTING-PLAN 8.2)"
    ip saddr 10.12.14.0/24 tcp dport 22 accept comment "lio: LAN ssh kept"
  '';

  hardware.enableAllFirmware = true;

  # Connectivity
  networking.networkmanager.enable = true;
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;

  # System76
  hardware.system76.enableAll = true;

  # Memory: compressed RAM swap first, small disk swapfile (hardware-configuration.nix) as overflow.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };
  boot.kernel.sysctl = {
    # zram is cheap to swap to; tuned per the Fedora/Pop!_OS zram defaults
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    # Start writeback at 256MiB dirty, throttle writers at 1GiB
    "vm.dirty_background_bytes" = 268435456;
    "vm.dirty_bytes" = 1073741824;
  };
  # MGLRU thrashing protection: keep the last 1s of working set resident
  systemd.tmpfiles.rules = [ "w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000" ];
  systemd.oomd = {
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
  };

  # Deduplicate the store on a timer instead of inline during every build
  nix.settings.auto-optimise-store = lib.mkForce false;
  nix.optimise.automatic = true;

  # ── Meshtastic / serial device access ──────────────────────────────────────
  # CH340/CH341 USB-to-serial (used by ThinkNode M5, many ESP32 boards, etc.)
  # TAG+="uaccess" grants access to the logged-in seat user (needed for
  # Chrome Web Serial flashers). GROUP="dialout" is the fallback for non-seat
  # access (SSH, scripts, etc.).
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", GROUP="dialout", MODE="0660", TAG+="uaccess"
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4", GROUP="dialout", MODE="0660", TAG+="uaccess"
  '';

  services = {
    # system76-power (via hardware.system76.enableAll) manages power profiles
    # and the Thelio fan curve (driven by k10temp Tctl); it conflicts with
    # power-profiles-daemon. Its "balanced" profile sets amd-pstate-epp EPP to
    # balance_performance, which makes the 9950X boost single cores to ~5.7 GHz
    # on tiny background wakeups -> Tctl spikes to 75-90°C -> fans ramp up and
    # down constantly. `epp-balance-power` (below) overrides EPP afterwards.
    # NOTE: running `system76-power profile ...` re-applies its own EPP; rerun
    # `systemctl restart epp-balance-power` afterwards.
    power-profiles-daemon.enable = false;

    # Binary cache server (drop-in nix-serve replacement)
    nix-serve = {
      enable = true;
      package = pkgs.nix-serve-ng;
      port = nixServe.port;
      # openFirewall = true;
      secretKeyFile = nixServe.secretKeyFile;
    };
  };

  # Apply EPP=balance_power after system76-power has set its profile.
  systemd.services.epp-balance-power = {
    description = "Set amd-pstate EPP to balance_power (quieter Thelio fans)";
    after = [ "system76-power.service" ];
    wants = [ "system76-power.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # system76-power applies the profile asynchronously after startup.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
    };
    script = ''
      for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        echo balance_power > "$f"
      done
    '';
  };

  nix.distributedBuilds = true;

  # Dedicated remote-build user for juni/gp3/oren (remote_lio_builds.nix).
  # Its key may only speak the nix daemon / store protocol.
  users.groups.nix-builder = { };
  users.users.nix-builder = {
    isSystemUser = true;
    group = "nix-builder";
    useDefaultShell = true;
    openssh.authorizedKeys.keys =
      lib.optional (fleet.global.remoteLioBuildsPubKey != null)
        ''command="/run/current-system/sw/bin/fleet-nix-build-receive",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ${fleet.global.remoteLioBuildsPubKey}'';
  };
  nix.settings.trusted-users = [ "nix-builder" ];
  # Allow emulation of aarch64-linux binaries for cross compiling
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  environment.systemPackages = with pkgs; [
    lua
    qdirstat
    ffmpeg-full
    appimage-run
    nodejs_24
    foot
    mpv
    firefox
    google-chrome
    nixBuildReceive
  ];
}
