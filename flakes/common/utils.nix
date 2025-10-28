# utils.nix
{
  /*
    Auto-imports all Nix files and directories within a given `path`.

    Args:
      path: The absolute path to the directory to scan.
            (e.g., `./.` or `/path/to/dir`)

    Returns:
      An attribute set where keys are the filenames (without .nix) or
      directory names, and values are the imported modules.

    It ignores:
    - Dotfiles (e.g., .git)
    - default.nix and flake.nix (common entry points)
    - Itself (utils.nix)
  */
  importAll = path:
    let
      # Read all entries in the given path
      entries = builtins.readDir path;

      # Get the names of all entries
      entryNames = builtins.attrNames entries;

      # Filter for entries we want to import
      filteredNames = builtins.filter (name:
        let
          entryType = entries.${name};
          isDotfile = builtins.substring 0 1 name == ".";
          isIgnoredFile = name == "default.nix" || name == "flake.nix" || name == "utils.nix";
          isNixFile = entryType == "regular" && builtins.match ".*\\.nix$" name != null;
          isDirectory = entryType == "directory";
        in
        !isDotfile && !isIgnoredFile && (isNixFile || isDirectory)
      ) entryNames;

      # Create an attribute { name = "key"; value = import ./path/key; } for each entry
      createAttr = name: {
        # The key for the final attribute set
        name =
          if builtins.match ".*\\.nix$" name != null
          # If it's a .nix file, strip the extension for the key name
          then builtins.elemAt (builtins.match "(.*)\\.nix$" name) 0
          # Otherwise, use the directory name
          else name;

        # The value is the imported file/directory
        value = import (path + "/${name}");
      };

    in
    # Convert the list of attributes into a single attribute set
    builtins.listToAttrs (map createAttr filteredNames);
}
