{
  nix-minecraft,
  pkgs,
  lib,
  ...
}:
let
  # Player-facing port for the Velocity proxy.
  # Must match the firewall rule on the host (see hosts/h003/_constants.nix).
  proxyPort = 25565;

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
    white-list = true; # Enforce whitelist on backend servers
    enforce-whitelist = true; # Kick players not on whitelist immediately
    spawn-protection = 0;
    difficulty = "normal";
    gamemode = "survival";
    motd = motd;
    max-players = 10;
    view-distance = 32;
    simulation-distance = 20;
    pvp = false;
  };

  # Paper per-world defaults. We enable the "unsupported" piston/TNT duping
  # knobs because we want classic survival-tech contraptions (TNT dupers,
  # bedrock breakers, headless-piston designs) to work.
  #
  # These flags live under `unsupported-settings` because Mojang considers
  # the underlying behaviour a bug; Paper disables them by default but
  # exposes toggles for servers that intentionally rely on them.
  paperWorldDefaults = {
    unsupported-settings = {
      allow-piston-duplication = true; # classic TNT/carpet/rail dupers
      allow-headless-pistons = true; # modern dupers + headless-piston contraptions
    };
  };

  # ── Plugin JARs ──────────────────────────────────────────────────────────
  # LuckPerms -- network-wide permissions (installed on Velocity + all backends)
  luckpermsVelocity = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/Vebnzrzj/versions/GZjsuCmU/LuckPerms-Velocity-5.5.17.jar";
    sha512 = "f1c12b25346d55731c3a939f7fe30ff3255f3e37c08e5af2ab501f010a60b6abf316f5d3db0022a26fbfe2c670e129d68240f627cdd33d6afad0ac093acf22ed";
  };
  luckpermsBukkit = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/Vebnzrzj/versions/OrIs0S6b/LuckPerms-Bukkit-5.5.17.jar";
    sha512 = "773895644260b338818bfeff0c78f8d4f590f56b0f711c378a4eec91be6e8b37354099b5db1ea5b2dce4c02486213297a6da09675c9bf6f014f9a400b5772cf3";
  };

  # WorldEdit (Fast Async) -- //wand, //set, //copy, //paste, etc.
  fawe = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/z4HZZnLr/versions/mHtmqIig/FastAsyncWorldEdit-Paper-2.15.0.jar";
    sha512 = "353cfb54600b90c5c30595e3357f680ec851319bcf95427b5ca319df4feee7b2b074f230b5b16a3d3f7dbd6d9ecc89b8e21941f645f1df08292c2dffa406db26";
  };

  # EssentialsX -- /home, /tpa, /warp, /spawn, /kit, etc.
  essentialsx = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/hXiIvTyT/versions/Oa9ZDzZq/EssentialsX-2.21.2.jar";
    sha512 = "0571b015dce84cf03e906c2d498e8bc3827d86debafafb89851517a76c3eec0391b9bb90f6ec4a5f0dbf4c18bee84ead5e354fc0a5be0cc567fdaa9fc8d96c15";
  };

  # ProtocolLib -- packet-level API used by many plugins
  protocollib = pkgs.fetchurl {
    url = "https://github.com/dmulloy2/ProtocolLib/releases/download/5.4.0/ProtocolLib.jar";
    sha256 = "ee2e7ab9b5386f2d103081c4d108e61b1035df2ca692b53d6e2409fb1f5caccf";
  };

  # PlaceholderAPI -- shared placeholder system for plugins
  placeholderapi = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/lKEzGugV/versions/UmbIiI5H/PlaceholderAPI-2.12.2.jar";
    sha512 = "94addf996ba45e16dbded3fcaf05e8b442212ce0d577f7edc42b743ad9532c1e24115263976126d36f27c0868ab1c03c40c2d13947985124b92dabca4527dddb";
  };

  # PAPIProxyBridge -- syncs PlaceholderAPI placeholders across Velocity
  papiproxybridge = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/bEIUEGTX/versions/jR1s02Y5/PAPIProxyBridge-Velocity-1.8.4.jar";
    sha512 = "136160b1b31be50ee8bf07797cc0420bfa63c9b3f9725f8a36d3970ffb2df06fcd2a9b1501e74f612ac1dd474af3412eae9cfa925230653e16f041c4642c4031";
  };

  # DeathChest -- spawns a chest on death instead of item drops (survival only)
  deathchest = pkgs.fetchurl {
    url = "https://hangarcdn.papermc.io/plugins/CyntrixAlgorithm/DeathChest/versions/2.2.9/PAPER/deathchest.jar";
    sha256 = "84fb0dd09386102951ad9c4a5b75a3541db866199168b49e4e36354426b9a35b";
  };

  # How long a death chest stays before despawning. Used in both the plugin
  # config and the user-facing notification message so they stay in sync.
  deathChestExpirySeconds = 1800; # 30 minutes
  deathChestExpiryHuman = "30 minutes";

  # Vault -- permission/economy bridge API. EssentialsX requires this to
  # expose LuckPerms group prefixes/suffixes in chat and other features.
  vault = pkgs.fetchurl {
    url = "https://github.com/MilkBowl/Vault/releases/download/1.7.3/Vault.jar";
    sha256 = "07fhfz7ycdlbmxsri11z02ywkby54g6wi9q0myxzap1syjbyvdd6";
  };

  # WorldEditSUI -- visual selection overlay for WorldEdit (creative only)
  worldeditsui = pkgs.fetchurl {
    url = "https://hangarcdn.papermc.io/plugins/kennytv/WorldEditSUI/versions/1.7.4/PAPER/WorldEditSUI-1.7.4.jar";
    sha256 = "7006cf9e5944c75e1b57cc19dc88ed17fc179a0e28354fda424aa32a95aac3d8";
  };

  # squaremap -- 2D top-down web map (survival only)
  squaremap = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/PFb7ZqK6/versions/GItyEkou/squaremap-paper-mc1.21.11-1.3.12.jar";
    sha512 = "b35306031aaec4d5cb32c52e0bde7e95321cbce24016e8e9fb9cc1161366c7ba352a864bf1f9a44240e35b886fd933f5fc1b20a2c02ea2ff0ca4b611e7259cd4";
  };

  # squaremap web port (survival map)
  squaremapPort = 8080;

  # ── LuckPerms storage (PostgreSQL) ──────────────────────────────────────
  # All three instances (velocity proxy + survival + creative) share a single
  # PostgreSQL database so permissions are synchronized across the network.
  #
  # Auth: peer-trust on 127.0.0.1 (see services.postgresql.authentication
  # below). The container has no exposed postgres port and the loopback
  # interface inside a NixOS container is isolated from the host, so trust
  # auth is safe here. This mirrors hosts/h001/containers/forgejo.nix.
  #
  # First-boot note: LuckPerms downloads the PostgreSQL JDBC driver from
  # Maven Central on first start. The container has internet access, so
  # this just works -- but expect a few extra seconds on the first launch
  # after switching storage methods. Schema is auto-created.
  luckpermsDbName = "luckperms";
  luckpermsDbUser = "luckperms";
  luckpermsConfig = serverType: {
    server = serverType;
    storage-method = "postgresql";
    data = {
      address = "127.0.0.1"; # default port 5432
      database = luckpermsDbName;
      username = luckpermsDbUser;
      password = ""; # ignored under trust auth
      pool-settings = {
        # Upstream defaults are MySQL-tuned. The useUnicode/characterEncoding
        # JDBC properties are not recognized by the PostgreSQL driver, so we
        # explicitly empty `properties` to avoid driver warnings on startup.
        properties = { };
      };
    };
    messaging-service = "pluginmsg"; # Sync changes across servers via Velocity
  };
in
{
  imports = [ nix-minecraft.nixosModules.minecraft-servers ];
  nixpkgs.overlays = [ nix-minecraft.overlay ];

  environment.systemPackages = [ pkgs.tmux ];

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

  # Make the minecraft server services depend on:
  #   - the forwarding secret existing (Velocity modern forwarding)
  #   - postgresql being up (LuckPerms storage backend)
  systemd.services.minecraft-server-velocity = {
    after = [
      "minecraft-forwarding-secret.service"
      "postgresql.service"
    ];
    requires = [
      "minecraft-forwarding-secret.service"
      "postgresql.service"
    ];
  };
  systemd.services.minecraft-server-survival = {
    after = [
      "minecraft-forwarding-secret.service"
      "postgresql.service"
    ];
    requires = [
      "minecraft-forwarding-secret.service"
      "postgresql.service"
    ];
  };
  systemd.services.minecraft-server-creative = {
    after = [
      "minecraft-forwarding-secret.service"
      "postgresql.service"
    ];
    requires = [
      "minecraft-forwarding-secret.service"
      "postgresql.service"
    ];
  };

  # ── PostgreSQL for LuckPerms ────────────────────────────────────────────
  # Single shared database used by Velocity + Paper backends for permissions.
  # Trust auth on loopback only -- nothing outside the container can reach
  # postgres. The `luckperms` role owns the `luckperms` database; LuckPerms
  # creates its own tables on first connect (prefixed `luckperms_`).
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    enableJIT = true;
    authentication = ''
      local all all trust
      host  all all 127.0.0.1/32 trust
      host  all all ::1/128      trust
    '';
    ensureDatabases = [ luckpermsDbName ];
    ensureUsers = [
      {
        name = luckpermsDbUser;
        ensureDBOwnership = true;
      }
    ];
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

        # Velocity plugins (individual symlinks so plugins/ stays writable for config dirs)
        symlinks."plugins/LuckPerms-Velocity.jar" = luckpermsVelocity;
        symlinks."plugins/PAPIProxyBridge.jar" = papiproxybridge;

        # LuckPerms config for the proxy
        files."plugins/luckperms/config.yml".value = luckpermsConfig "proxy";
      };

      # ── Paper: Survival (primary) ────────────────────────────────────
      # Main unmodified Paper server. Plugins will NOT be added here
      # beyond LuckPerms for network-wide permissions.
      survival = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms4096M -Xmx12288M"; # Matches original joe config
        serverProperties = paperServerProperties 25566 "Survival" // {
          force-gamemode = true; # Force survival on join
        };
        whitelist = whitelist;
        operators = operators;

        symlinks."plugins/LuckPerms.jar" = luckpermsBukkit;
        symlinks."plugins/Vault.jar" = vault;
        symlinks."plugins/EssentialsX.jar" = essentialsx;
        symlinks."plugins/ProtocolLib.jar" = protocollib;
        symlinks."plugins/PlaceholderAPI.jar" = placeholderapi;
        symlinks."plugins/DeathChest.jar" = deathchest;
        symlinks."plugins/squaremap.jar" = squaremap;
        files."plugins/LuckPerms/config.yml".value = luckpermsConfig "survival";

        # squaremap -- enable Nether and End rendering.
        #
        # By default squaremap "enables" all worlds, but the Nether map looks
        # like solid bedrock because the renderer iterates downward from the
        # top of the build limit and immediately hits the Nether ceiling.
        # Setting `iterate-up: true` + `max-height: 127` makes it render the
        # Nether floor properly (everything from y=0 looking upward, capped
        # just below the bedrock ceiling).
        #
        # The End is fine with default top-down rendering since it has no
        # ceiling, but we set a friendlier display name for the web UI.
        #
        # Squaremap reads per-world settings from `world-settings.<worldname>`
        # falling back to `world-settings.default.*`. World names use the
        # vanilla resource-location key (with `:` replaced by `_`).
        files."plugins/squaremap/config.yml".value = {
          settings = {
            web-address = "http://localhost:${toString squaremapPort}";
            internal-webserver = {
              enabled = true;
              bind = "0.0.0.0";
              port = squaremapPort;
            };
          };
          world-settings = {
            default = {
              # Inherited by every world unless overridden below
              map.enabled = true;
              map.background-render.enabled = true;
            };
            minecraft_overworld = {
              map.display-name = "Overworld";
              map.order = 0;
            };
            minecraft_the_nether = {
              map.display-name = "Nether";
              map.order = 1;
              map.enabled = true;
              # Render upward from y=0 instead of downward from build limit,
              # otherwise the entire map shows bedrock ceiling.
              map.iterate-up = true;
              # Cap render height just below the Nether bedrock ceiling (y=128)
              map.max-height = 127;
            };
            minecraft_the_end = {
              map.display-name = "The End";
              map.order = 2;
              map.enabled = true;
            };
          };
        };

        # DeathChest -- expiry controlled by deathChestExpiry* bindings above
        files."plugins/DeathChest/config.yml".value = {
          update-checker = false;
          auto-update = false;
          duration-format = "mm'm' ss's'";
          chest = {
            expiration = deathChestExpirySeconds;
            drop-items-after-expiration = true;
            blast-protection = true;
            no-expiration-permission = {
              enabled = false;
              permission = "deathchest.stays-forever";
            };
            thief-protection.enabled = false;
          };
          player-notification = {
            enabled = true;
            message = "&7You died. Your items were put into a chest which disappears after &c${deathChestExpiryHuman}&7! \${x} \${y} \${z}";
          };
          config-version = 3;
        };

        # Paper reads the secret from paper-global.yml, but we use
        # @FORWARDING_SECRET@ substitution from an environment file.
        files."config/paper-global.yml".value = {
          proxies.velocity = {
            enabled = true;
            online-mode = true;
            secret = "@FORWARDING_SECRET@";
          };
        };

        files."config/paper-world-defaults.yml".value = paperWorldDefaults;
      };

      # ── Paper: Creative (secondary) ──────────────────────────────────
      # Second Paper instance for plugin experimentation later.
      # Creative mode with normal world gen.
      creative = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms2048M -Xmx8192M";
        serverProperties = paperServerProperties 25567 "Creative" // {
          gamemode = "creative";
          force-gamemode = true; # Force creative on join (overrides per-player)
          spawn-monsters = false;
          spawn-animals = false;
        };
        whitelist = whitelist;
        operators = operators;

        symlinks."plugins/LuckPerms.jar" = luckpermsBukkit;
        symlinks."plugins/Vault.jar" = vault;
        symlinks."plugins/EssentialsX.jar" = essentialsx;
        symlinks."plugins/ProtocolLib.jar" = protocollib;
        symlinks."plugins/PlaceholderAPI.jar" = placeholderapi;
        symlinks."plugins/FastAsyncWorldEdit.jar" = fawe;
        symlinks."plugins/WorldEditSUI.jar" = worldeditsui;
        files."plugins/LuckPerms/config.yml".value = luckpermsConfig "creative";

        files."config/paper-global.yml".value = {
          proxies.velocity = {
            enabled = true;
            online-mode = true;
            secret = "@FORWARDING_SECRET@";
          };
        };

        files."config/paper-world-defaults.yml".value = paperWorldDefaults;
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

  # ── Unified tmux session for all server consoles ─────────────────────────
  # Attach with: tmux attach -t mc
  # Windows: 1=velocity, 2=survival, 3=creative
  systemd.services.minecraft-tmux = {
    description = "Tmux session with all Minecraft server consoles";
    wantedBy = [ "multi-user.target" ];
    after = [
      "minecraft-server-velocity.service"
      "minecraft-server-survival.service"
      "minecraft-server-creative.service"
    ];
    requires = [
      "minecraft-server-velocity.service"
      "minecraft-server-survival.service"
      "minecraft-server-creative.service"
    ];
    serviceConfig = {
      Type = "forking";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "mc-tmux-start" ''
        # Wait briefly for server sockets to appear
        sleep 3
        ${pkgs.tmux}/bin/tmux new-session -d -s mc -n velocity
        ${pkgs.tmux}/bin/tmux send-keys -t mc:velocity "${pkgs.tmux}/bin/tmux -S /run/minecraft/velocity.sock attach" Enter
        ${pkgs.tmux}/bin/tmux new-window -t mc -n survival
        ${pkgs.tmux}/bin/tmux send-keys -t mc:survival "${pkgs.tmux}/bin/tmux -S /run/minecraft/survival.sock attach" Enter
        ${pkgs.tmux}/bin/tmux new-window -t mc -n creative
        ${pkgs.tmux}/bin/tmux send-keys -t mc:creative "${pkgs.tmux}/bin/tmux -S /run/minecraft/creative.sock attach" Enter
        # Select velocity window by default
        ${pkgs.tmux}/bin/tmux select-window -t mc:velocity
      '';
      ExecStop = "${pkgs.tmux}/bin/tmux kill-session -t mc";
    };
  };

  system.stateVersion = "25.11";
}
