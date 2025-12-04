{
  ...
}:
{
  time.timeZone = null;
  services.automatic-timezoned.enable = true;

    # Add a polkit rule so automatic-timezoned can change timezone
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.timedate1.set-timezone" &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';
}
