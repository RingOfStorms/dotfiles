{ ... }:
{
  programs.git = {
    enable = true;
    # TODO make configurable
    userEmail = "ringofstorms@gmail.com";
    userName = "RingOfStorms (Joshua Bell)";

    extraConfig = {
      core.pager = "bat";
      core.editor = "nano";

      pull.rebase = false;

      init.defaultBranch = "main";

      rerere.enabled = true;
    };

    difftastic = {
      enable = true;
      background = "dark";
    };

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
      ".direnv"
      ".envrc"

      # local only files
      "*.local"
    ];
  };
}
