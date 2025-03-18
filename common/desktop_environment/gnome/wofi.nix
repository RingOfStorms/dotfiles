{ cfg }:
{ lib, ... }:
{
  config = lib.mkIf cfg.enable {
    home-manager.sharedModules = [
      (
        { lib, ... }:
        {
          programs.wofi = {
            enable = true;
            settings = {
              width = "28%";
              height = "38%";
              show = "drun";
              location = "center";
              gtk_dark = true;
              valign = "center";
              key_backward = "Ctrl+k";
              key_forward = "Ctrl+j";
              insensitive = true;
              prompt = "Run";
              allow_images = true;
            };
            style = builtins.readFile ./wofi.css;
          };
        }
      )
    ];

  };
}
