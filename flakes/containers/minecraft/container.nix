{ nix-minecraft, pkgs, lib, ... }:
let
  # Shared forwarding secret for Velocity <-> Paper modern forwarding.
  # Must be identical across Velocity's forwarding.secret and each Paper
  # server's paper-global.yml. Replace with a real random string.
  forwardingSecret = "J3qHvMspR8cNk7Fz9wXd";

  # Whitelist shared across servers
  whitelist = {
    lnsanehero = "8ea7c69d-9878-464a-9572-c3f783affc78";
    Jedicraftt = "00dabc59-bfda-4101-b3e1-6925d5ce8268";
    sdking13 = "11766f4b-b08f-41bf-abbd-781e53f90ea8";
    RingOfStorms = "fe5b7d3e-73d9-4587-8b6f-743e5edf8e7f";
    Tacobellington = "b79b741f-a436-497c-af3e-49dd5f724868";
    drogo_senturi = "a5f22509-bef5-46af-bafa-51b3ce0147e9";
    BlockEmpires = "f1572c9b-34a8-463f-8329-18b7abae943c";
  };

  # Shared Paper server properties (both servers use the same base config)
  paperServerProperties = port: motd: {
    server-port = port;
    online-mode = false; # Velocity handles authentication
    white-list = false; # Velocity handles this
    spawn-protection = 0;
    difficulty = "normal";
    gamemode = "survival";
    motd = motd;
    max-players = 10;
    view-distance = 32;
    simulation-distance = 20;
    pvp = false;
  };

  # Paper velocity forwarding config (injected into paper-global.yml)
  paperVelocityConfig = {
    value = {
      proxies.velocity = {
        enabled = true;
        online-mode = true;
        secret = forwardingSecret;
      };
    };
  };
in
{
  imports = [ nix-minecraft.nixosModules.minecraft-servers ];
  nixpkgs.overlays = [ nix-minecraft.overlay ];

  services.minecraft-servers = {
    enable = true;
    eula = true;
    openFirewall = true;

    servers = {
      # ── Velocity Proxy ────────────────────────────────────────────────
      # Player-facing entry point. Players connect here on 25565.
      # Routes to backend Paper servers on localhost.
      velocity = {
        enable = true;
        package = pkgs.velocityServers.velocity;
        jvmOpts = "-Xms512M -Xmx1024M";

        symlinks."velocity.toml".value = {
          config-version = "2.7";
          bind = "0.0.0.0:25565";
          motd = "<green>Computer Boyz";
          show-max-players = 10;
          online-mode = true;
          player-info-forwarding-mode = "modern";

          servers.survival = "127.0.0.1:25566";
          servers.creative = "127.0.0.1:25567";
          servers.try = [ "survival" ];

          forced-hosts = { };

          query = {
            enabled = false;
            port = 25565;
          };
        };

        # The forwarding secret file that backends must match
        files."forwarding.secret" = forwardingSecret;
      };

      # ── Paper: Survival (primary) ────────────────────────────────────
      # Main unmodified Paper server. Plugins will NOT be added here.
      survival = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms4096M -Xmx12288M";
        serverProperties = paperServerProperties 25566 "Survival";
        whitelist = whitelist;

        files."config/paper-global.yml" = paperVelocityConfig;
      };

      # ── Paper: Creative (secondary) ──────────────────────────────────
      # Second Paper instance for plugin experimentation later.
      creative = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms2048M -Xmx4096M";
        serverProperties = paperServerProperties 25567 "Creative";
        whitelist = whitelist;

        files."config/paper-global.yml" = paperVelocityConfig;
      };
    };
  };

  # ── Daily restart at 4 AM ───────────────────────────────────────────────
  systemd.timers.minecraft-restart = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
    };
  };
  systemd.services.minecraft-restart = {
    description = "Restart all Minecraft servers";
    serviceConfig.Type = "oneshot";
    script = ''
      systemctl restart minecraft-server-velocity
      systemctl restart minecraft-server-survival
      systemctl restart minecraft-server-creative
    '';
  };

  system.stateVersion = "25.11";
}
