{
  constants,
  pkgs,
  lib,
  ...
}:
let
  c = constants.services.minecraft;
in
{
  # ── Minecraft Java client (Prismlauncher) ──────────────────────────────────
  environment.systemPackages = with pkgs; [
    prismlauncher # Open-source Minecraft launcher (multi-instance, mods, modpacks)
  ];

  # ── Minecraft server ───────────────────────────────────────────────────────
  services.minecraft-server = {
    enable = true;
    eula = true;
    openFirewall = true; # Opens the default port on all interfaces
    declarative = true;
    jvmOpts = "-Xmx12288M -Xms4096M";
    serverProperties = {
      server-port = c.port;
      online-mode = true;
      white-list = true;
      spawn-protection = 0;
      difficulty = "normal";
      gamemode = "survival";
      motd = "Computer Boyz";
      max-players = 10;
      view-distance = 32;
      simulation-distance = 20;
      pvp = false;
    };
    whitelist = {
      lnsanehero = "8ea7c69d-9878-464a-9572-c3f783affc78";
      Jedicraftt = "00dabc59-bfda-4101-b3e1-6925d5ce8268";
      sdking13 = "11766f4b-b08f-41bf-abbd-781e53f90ea8";
      RingOfStorms = "fe5b7d3e-73d9-4587-8b6f-743e5edf8e7f";
      Tacobellington = "b79b741f-a436-497c-af3e-49dd5f724868";
      drogo_senturi = "a5f22509-bef5-46af-bafa-51b3ce0147e9";
      BlockEmpires = "f1572c9b-34a8-463f-8329-18b7abae943c";
    };
  };

  # Disable DynamicUser so /var/lib/minecraft can be a direct bind mount
  # (impermanence bind mounts conflict with systemd's DynamicUser /var/lib/private setup)
  systemd.services.minecraft-server.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "minecraft";
    Group = "minecraft";
  };

  # ── Daily restart at 4 AM ────────────────────────────────────────────────
  systemd.timers.minecraft-server-restart = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
    };
  };

  systemd.services.minecraft-server-restart = {
    description = "Restart Minecraft server";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart minecraft-server.service";
    };
  };

  users.users.minecraft = {
    isSystemUser = true;
    group = "minecraft";
    home = "/var/lib/minecraft";
  };
  users.groups.minecraft = {};
}
