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

  # WorldEditSUI -- visual selection overlay for WorldEdit (creative only)
  worldeditsui = pkgs.fetchurl {
    url = "https://hangarcdn.papermc.io/plugins/kennytv/WorldEditSUI/versions/1.7.4/PAPER/WorldEditSUI-1.7.4.jar";
    sha256 = "7006cf9e5944c75e1b57cc19dc88ed17fc179a0e28354fda424aa32a95aac3d8";
  };

  # SmartLock -- chest/container locking with /lock
  smartlock = pkgs.fetchurl {
    url = "https://hangarcdn.papermc.io/plugins/GroupMoro/SmartLock/versions/1.0.3/PAPER/SmartLock-1.0.3.jar";
    sha256 = "3d51d63da0d3a55fa97c4e3278c67109b157f5bc76393ed7c22d647d2db1af36";
  };

  # squaremap -- 2D top-down web map (survival only)
  squaremap = pkgs.fetchurl {
    url = "https://cdn.modrinth.com/data/PFb7ZqK6/versions/GItyEkou/squaremap-paper-mc1.21.11-1.3.12.jar";
    sha512 = "b35306031aaec4d5cb32c52e0bde7e95321cbce24016e8e9fb9cc1161366c7ba352a864bf1f9a44240e35b886fd933f5fc1b20a2c02ea2ff0ca4b611e7259cd4";
  };

  # squaremap web port (survival map)
  squaremapPort = 8080;

  # Shared LuckPerms config -- all instances use the same file-based storage
  # so permissions are synchronized across the network.
  # Data lives at /srv/minecraft/.luckperms-shared/ inside the container.
  luckpermsConfig = serverType: {
    server = serverType;
    storage-method = "h2"; # Shared H2 file database
    data.address = "/srv/minecraft/.luckperms-shared/luckperms-h2";
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
        symlinks."plugins/EssentialsX.jar" = essentialsx;
        symlinks."plugins/ProtocolLib.jar" = protocollib;
        symlinks."plugins/PlaceholderAPI.jar" = placeholderapi;
        symlinks."plugins/DeathChest.jar" = deathchest;
        symlinks."plugins/SmartLock.jar" = smartlock;
        symlinks."plugins/squaremap.jar" = squaremap;
        files."plugins/LuckPerms/config.yml".value = luckpermsConfig "survival";

        # DeathChest -- 14 real days expiry (1209600 seconds)
        files."plugins/DeathChest/config.yml".value = {
          update-checker = false;
          auto-update = false;
          duration-format = "dd'd' HH'h' mm'm' ss's'";
          chest = {
            expiration = 1209600;
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
            message = "&7You died. Your items were put into a chest which disappears after &c14 days&7! \${x} \${y} \${z}";
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
      };

      # ── Paper: Creative (secondary) ──────────────────────────────────
      # Second Paper instance for plugin experimentation later.
      # Creative mode with normal world gen.
      creative = {
        enable = true;
        package = pkgs.paperServers.paper;
        jvmOpts = "-Xms2048M -Xmx4096M";
        serverProperties = paperServerProperties 25567 "Creative" // {
          gamemode = "creative";
          force-gamemode = true; # Force creative on join (overrides per-player)
          spawn-monsters = false;
          spawn-animals = false;
        };
        whitelist = whitelist;
        operators = operators;

        symlinks."plugins/LuckPerms.jar" = luckpermsBukkit;
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
