# Standard XDG user dirs (Downloads, Documents, etc.). Persist on any
# host where a real human logs in and might save files.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [
      "Downloads"
      "Documents"
      "Desktop"
      "Public"
      "Videos"
      "Pictures"
    ];
    files = [ ];
  };
}
