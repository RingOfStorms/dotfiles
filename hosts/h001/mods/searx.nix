{
  constants,
  ...
}:
let
  c = constants.services.searx;
in
{
  # Private backend for Open WebUI web search. No nginx vhost or firewall rule.
  services.searx = {
    enable = true;
    openFirewall = false;
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = c.port;
      };
      search = {
        formats = [ "html" "json" ];
        safe_search = 1;
      };
      outgoing = {
        request_timeout = 10.0;
        max_request_timeout = 15.0;
      };
    };
  };
}
