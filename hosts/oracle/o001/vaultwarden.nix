{
  ...
}:
{
  containers.vaultwarden = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = "192.168.100.2";
    localAddress = "192.168.100.12";
    bindMounts = {
      "/incontainer" = {
        hostPath = "/asd";
        isReadOnly = false;
      };
    };
    config =
      { ... }:
      {
        services.vaultwarden = {
          enable = true;
          dbBackend = "sqlite";
          backupDir = "/asd";
          config = {
            DOMAIN = "https://vault.joshuabell.xyz";
            SIGNUPS_ALLOWED = true;
          };
        };
      };
  };
}
