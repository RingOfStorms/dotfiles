# Guest config. forgejo HTTP :3000 on fleetNet.bindAddress (0.0.0.0 in the
# private netns), builtin SSH :3032 on 0.0.0.0; postgres on its unix socket
# only. uid/gid 115 pinned to match the copied data.
{
  pkgs,
  lib,
  fleetNet,
  ...
}:
{
  system.stateVersion = "24.11";

  users.users.forgejo.uid = 115;
  users.groups.forgejo.gid = 115;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17.withJIT;
    enableJIT = true;
    dataDir = "/var/lib/postgresql/17";
    settings.listen_addresses = lib.mkForce "";
    authentication = lib.mkForce ''
      local all all trust
    '';
  };
  services.postgresqlBackup.enable = true;

  services.forgejo = {
    enable = true;
    package = pkgs.forgejo;
    database.type = "postgres";
    settings = {
      DEFAULT.APP_NAME = "Josh's Git";
      server = {
        PROTOCOL = "http";
        DOMAIN = "git.joshuabell.xyz";
        ROOT_URL = "https://git.joshuabell.xyz/";
        HTTP_ADDR = fleetNet.bindAddress;
        HTTP_PORT = 3000;

        START_SSH_SERVER = true;
        SSH_DOMAIN = "git.joshuabell.xyz";
        SSH_LISTEN_HOST = "0.0.0.0"; # host network too: o002 + tailnet reach it directly
        SSH_LISTEN_PORT = 3032; # actual listen port
        SSH_PORT = 3032; # used in UI
        BUILTIN_SSH_SERVER_USER = "git";
        SSH_SERVER_KEY_EXCHANGES = "mlkem768x25519-sha256";

        LANDING_PAGE = "explore";
      };
      service = {
        DISABLE_REGISTRATION = true;
        ENABLE_BASIC_AUTHENTICATION = false;
        DISABLE_USERS_PAGE = true;
        DISABLE_ORGANIZATIONS_PAGE = true;
      };
      repository = {
        DISABLE_STARS = true;
        DEFAULT_PRIVATE = "private";
      };
      admin = {
        DISABLE_REGULAR_ORG_CREATION = true;
        USER_DISABLED_FEATURES = "deletion";
      };
      other = {
        SHOW_FOOTER_POWERED_BY = false;
        SHOW_FOOTER_VERSION = false;
        SHOW_FOOTER_TEMPLATE_LOAD_TIME = false;
      };
      migrations = {
        ALLOWED_DOMAINS = "*.github.com,github.com,codeberg.org,*.codeberg.org";
        ALLOW_LOCALNETWORKS = true;
      };
      # Map file extensions to Chroma lexers for syntax highlighting.
      # Lisette (.lis) has no Chroma lexer; its syntax is Rust-derived
      # (fn/let mut/match/impl/enum/Option/Result/closures/?), so the
      # Rust lexer is the closest fit. Lisette-only constructs
      # (|> pipeline, task/select/recover/try blocks, f-strings,
      # `import "go:..."`) will not highlight correctly.
      "highlight.mapping".".lis" = "rust";
    };
  };
}
