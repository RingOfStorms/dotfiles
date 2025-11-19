{
  ...
}:
{
  config = {
    services.beszel.hub = {
      enable = true;
      port = 8090;
      host = "100.64.0.13";
      environment = {
        # DISABLE_PASSWORD_AUTH = "true"; # Once sso is setup
      };
    };
  };
}
