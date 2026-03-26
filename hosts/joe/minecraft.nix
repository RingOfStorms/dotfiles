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
    serverProperties = {
      server-port = c.port;
      online-mode = true;
      white-list = true;
      difficulty = "normal";
      gamemode = "survival";
      motd = "Joe's Minecraft Server";
      max-players = 10;
      view-distance = 16;
      simulation-distance = 10;
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
