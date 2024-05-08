{ settings, ... }:
{
  programs.git = {
    enable = true;
    userEmail = settings.user.git.email;
    userName = settings.user.git.name;

    extraConfig = {
      core.pager = "cat";
      core.editor = "nvim";

      pull.rebase = false;
    };

    difftastic = {
      enable = true;
      background = "dark";
    };

    # TODO move from common system? Need root user home managed too...
    # aliases: {}

    ignores = [
      # --------------
      #    Intellij
      # --------------
      "*.iml"
      # --------------
      #    MAC OS
      # --------------
      ".DS_Store"
      ".AppleDouble"
      ".LSOverride"
      # Icon must end with two \r
      "Icon"
      # Thumbnails
      "._*"
      # Files that might appear in the root of a volume
      ".DocumentRevisions-V100"
      ".fseventsd"
      ".Spotlight-V100"
      ".TemporaryItems"
      ".Trashes"
      ".VolumeIcon.icns"
      ".com.apple.timemachine.donotpresent"

      # Directories potentially created on remote AFP share
      ".AppleDB"
      ".AppleDesktop"
      "Network Trash Folder"
      "Temporary Items"
      ".apdisk"

      # direnv things
      "/.direnv"

      # local only files
      "*.local"
    ];
  };
}
