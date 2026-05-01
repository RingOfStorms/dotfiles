# Mozilla Firefox user profile (cookies, logins, extensions, sessions, etc.).
#
# Recent Firefox versions (>=140-ish) honor XDG and store the profile
# under ~/.config/mozilla/firefox instead of the legacy ~/.mozilla.
# Cache stays at ~/.cache/mozilla and is intentionally not persisted.
# Both ~/.mozilla and the new XDG path are listed so older firefox
# builds on other hosts still get covered.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [
      ".mozilla"
      ".config/mozilla"
    ];
    files = [ ];
  };
}
