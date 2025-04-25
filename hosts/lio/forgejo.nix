{
  config,
  pkgs,
  ...
}:
let

in
{
  options.services.forgejo = {

  };

  config = {
    services.forgejo = {
      enable = true;
      settings = {
        DEFAULT = {
          APP_NAME = "appname";
          APP_SLOGAN = "slogan";
        };
        server = {
          PROTOCOL = "http";
          # DOMAIN = "git.joshuabell.xyz";
          HTTP_ADDR = "0.0.0.0";
          HTTP_PORT = 3032;

          LANDING_PAGE = "explore";
        };
        service = {
          DISABLE_REGISTRATION = "true";
          ENABLE_BASIC_AUTHENTICATION = "false";
          # explore = {
          #   DISABLE_USERS_PAGE = "true";
          # };
        };
        repository = {
          DISABLE_STARS = "true";
          DEFAULT_PRIVATE = "private";
        };
        admin = {

          DISABLE_REGULAR_ORG_CREATION = "true";
          USER_DISABLED_FEATURES = "deletion";
        };
      };
    };
  };
}
