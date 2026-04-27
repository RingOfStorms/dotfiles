# Cached timezone name so automatic-timezoned has a sane fallback when
# starting up offline (no GeoIP/network on early boot).
{
  system = {
    directories = [ "/var/lib/timezone-cache" ];
    files = [ ];
  };
  user = {
    directories = [ ];
    files = [ ];
  };
}
