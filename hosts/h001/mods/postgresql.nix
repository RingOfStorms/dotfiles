{
  pkgs,
  ...
}:
{
  config = {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17.withJIT;
      enableJIT = true;
      authentication = ''
        local all all trust
        host all all 127.0.0.1/8 trust
        host all all ::1/128 trust
        host all all fc00::1/128 trust
      '';
    };

    # Backup database
    services.postgresqlBackup = {
      enable = true;
    };
  };
}
