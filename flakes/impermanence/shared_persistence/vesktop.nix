# Vesktop (Discord client): account session, settings, and cached
# assets. Persisting the whole ~/.config/vesktop directory keeps the
# user logged in across reboots.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [ ".config/vesktop" ];
    files = [ ];
  };
}
