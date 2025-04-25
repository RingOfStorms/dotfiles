{
  pkgs,
  ...
}:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17.withJIT;
    enableJIT = true;
    extensions = with pkgs.postgresql17Packages; [
      # NOTE add extensions here
      pgvector
      postgis
      pgsodium
      pg_squeeze
    ];
    authentication = ''
      local all all trust
      host all all 127.0.0.1/8 trust
      host all all ::1/128 trust
      host all all 192.168.100.0/24 trust
    '';
  };

  services.postgresqlBackup = {
    enable = true;
  };
}
