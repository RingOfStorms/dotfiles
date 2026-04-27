# Tailscale node identity and routing state. Without this you re-auth
# every boot.
{
  system = {
    directories = [ "/var/lib/tailscale" ];
    files = [ ];
  };
  user = {
    directories = [ ];
    files = [ ];
  };
}
