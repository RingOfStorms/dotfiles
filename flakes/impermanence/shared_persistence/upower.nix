# UPower battery history (lets the time-remaining estimate be useful
# from the first second after boot).
{
  system = {
    directories = [ "/var/lib/upower" ];
    files = [ ];
  };
  user = {
    directories = [ ];
    files = [ ];
  };
}
