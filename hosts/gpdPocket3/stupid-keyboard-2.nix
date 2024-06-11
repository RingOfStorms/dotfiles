{ ... }:
{
  services.keyd = {
    enable = true;
    # `keyd monitor` to get new keys to remap
    keyboards = {
      rgo_sino_keyboard = {
        ids = [ "04e8:7021" ];
        settings = {
          main = {
            "up" = "/";
            "/" = "up";
          };
        };
      };
    };
  };
}
