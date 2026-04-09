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
    jvmOpts = "-Xmx12288M -Xms12288M";
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
    };
  };

  # Disable DynamicUser so /var/lib/minecraft can be a direct bind mount
  # (impermanence bind mounts conflict with systemd's DynamicUser /var/lib/private setup)
  systemd.services.minecraft-server.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "minecraft";
    Group = "minecraft";
  };

  users.users.minecraft = {
    isSystemUser = true;
    group = "minecraft";
    home = "/var/lib/minecraft";
  };
  users.groups.minecraft = {};
}
