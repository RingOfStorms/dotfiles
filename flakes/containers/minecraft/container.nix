{ nix-minecraft, pkgs, lib, ... }:
let
  # Player-facing port for the Velocity proxy.
  # Must match the firewall rule on the host (see hosts/h003/_constants.nix).
  proxyPort = 25560;

  # Path where the shared forwarding secret lives (generated on first boot).
  # Must be identical across Velocity and each Paper backend.
  secretPath = "/var/lib/minecraft-secrets/forwarding.secret";

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

  # Operators (server admins)
  operators = {
    BlockEmpires = {
      uuid = "f1572c9b-34a8-463f-8329-18b7abae943c";
      level = 4;
      bypassesPlayerLimit = true;
    };
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
in
{
  imports = [ nix-minecraft.nixosModules.minecraft-servers ];
  nixpkgs.overlays = [ nix-minecraft.overlay ];

  # Open the Velocity proxy port inside the container's firewall
  networking.firewall.allowedTCPPorts = [ proxyPort ];

  # ── Generate forwarding secret on first boot ────────────────────────────
  # Creates a random secret once and reuses it forever. All minecraft
  # services wait for this before starting.
  systemd.services.minecraft-forwarding-secret = {
    description = "Generate Velocity forwarding secret if missing";
    wantedBy = [ "multi-user.target" ];
    before = [
      "minecraft-server-velocity.service"
      "minecraft-server-survival.service"
      "minecraft-server-creative.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -f "${secretPath}" ]; then
        mkdir -p "$(dirname "${secretPath}")"
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "${secretPath}"
        chmod 644 "${secretPath}"
        echo "Generated new forwarding secret"
      fi
    '';
  };

  # Make the minecraft server services depend on the secret existing
  systemd.services.minecraft-server-velocity = {
    after = [ "minecraft-forwarding-secret.service" ];
    requires = [ "minecraft-forwarding-secret.service" ];
  };
  systemd.services.minecraft-server-survival = {
    after = [ "minecraft-forwarding-secret.service" ];
    requires = [ "minecraft-forwarding-secret.service" ];
  };
  systemd.services.minecraft-server-creative = {
    after = [ "minecraft-forwarding-secret.service" ];
    requires = [ "minecraft-forwarding-secret.service" ];
  };

  services.minecraft-servers = {
    enable = true;
    eula = true;
    openFirewall = true;

    servers = {
      # ── Velocity Proxy ────────────────────────────────────────────────
      # Player-facing entry point. Players connect here on proxyPort.
      # Routes to backend Paper servers on localhost.
      velocity = {
        enable = true;
        package = pkgs.velocityServers.velocity;
        jvmOpts = "-Xms512M -Xmx1024M";

        symlinks."velocity.toml".value = {
          config-version = "2.7";
          bind = "0.0.0.0:${toString proxyPort}";
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
            port = proxyPort;
          };
        };

        # Symlink the generated secret into Velocity's data dir
        symlinks."forwarding.secret" = secretPath;
      };

      # ── Paper: Survival (primary) ────────────────────────────────────
      # Main unmodified Paper server. Plugins will NOT be added here.
      survival = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms4096M -Xmx12288M"; # Matches original joe config
        serverProperties = paperServerProperties 25566 "Survival" // {
          force-gamemode = true; # Force survival on join
        };
        whitelist = whitelist;
        operators = operators;

        # Paper reads the secret from paper-global.yml, but we use
        # @FORWARDING_SECRET@ substitution from an environment file.
        files."config/paper-global.yml".value = {
          proxies.velocity = {
            enabled = true;
            online-mode = true;
            secret = "@FORWARDING_SECRET@";
          };
        };
      };

      # ── Paper: Creative (secondary) ──────────────────────────────────
      # Second Paper instance for plugin experimentation later.
      # Superflat world in creative mode.
      creative = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms2048M -Xmx4096M";
        serverProperties = paperServerProperties 25567 "Creative" // {
          gamemode = "creative";
          force-gamemode = true; # Force creative on join (overrides per-player)
          level-type = "flat";
          spawn-monsters = false;
          spawn-animals = false;
        };
        whitelist = whitelist;
        operators = operators;

        files."config/paper-global.yml".value = {
          proxies.velocity = {
            enabled = true;
            online-mode = true;
            secret = "@FORWARDING_SECRET@";
          };
        };
      };
    };

    # Environment file for @VAR@ substitution in `files` entries.
    # nix-minecraft replaces @FORWARDING_SECRET@ with the value at runtime.
    environmentFile = "/var/lib/minecraft-secrets/env";
  };

  # Generate the env file from the secret on boot (after secret exists)
  systemd.services.minecraft-forwarding-env = {
    description = "Generate environment file from forwarding secret";
    wantedBy = [ "multi-user.target" ];
    after = [ "minecraft-forwarding-secret.service" ];
    requires = [ "minecraft-forwarding-secret.service" ];
    before = [
      "minecraft-server-velocity.service"
      "minecraft-server-survival.service"
      "minecraft-server-creative.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      echo "FORWARDING_SECRET=$(cat ${secretPath})" > /var/lib/minecraft-secrets/env
      chmod 644 /var/lib/minecraft-secrets/env
    '';
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
