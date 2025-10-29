{ pkgs, ... }:
{
  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic";
    size = 14;
  };

  # Ensure all X11 apps see the same cursor settings
  xresources.properties = {
    "Xcursor.theme" = "Bibata-Modern-Classic";
    "Xcursor.size" = 14;
  };
  home.sessionVariables = {
    XCURSOR_THEME = "Bibata-Modern-Classic";
    XCURSOR_SIZE = "14";
  };

  gtk = {
    enable = true;
    theme = { package = pkgs.flat-remix-gtk; name = "Flat-Remix-GTK-Grey-Darkest"; };
    iconTheme = { package = pkgs.adwaita-icon-theme; name = "Adwaita"; };
    font = { name = "Sans"; size = 11; };
  };
}
