{ settings, ylib, ... } @ _args:
{
  imports =
    # Common settings all users share
    [ (settings.usersDir + "/_common/home.nix") ]
    # User programs
    ++ ylib.umport {
      paths = [ ./programs ];
      recursive = true;
    }
    # User theme
    ++ ylib.umport {
      paths = [ ./theme ];
      recursive = true;
    };
}
