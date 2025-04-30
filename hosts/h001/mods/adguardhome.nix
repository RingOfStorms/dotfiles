{
  ...
}:
{
  config = {
    services.adguardhome = {
      enable = true;
      allowDHCP = true;
      openFirewall = true;
    };
  };
}
