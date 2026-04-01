{
  host = {
    name = "oren";
    overlayIp = "100.64.0.5";
    primaryUser = "josh";
    stateVersion = "25.05";
  };

  services = { };

  secrets = {
    "rustdesk_server_key" = {
      kvPath = "kv/data/machines/low-trust/rustdesk_server_key";
      softDepend = [ "rustdesk" ];
    };
    "rustdesk_password" = {
      kvPath = "kv/data/machines/low-trust/rustdesk_password";
      softDepend = [ "rustdesk" ];
    };
  };
}
