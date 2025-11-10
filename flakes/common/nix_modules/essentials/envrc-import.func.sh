# Function to import a .envrc from a central repository of flake wrappers
# It finds all subdirectories in a configured path that contain a .envrc file,
# lets you choose one with fzf, and appends its content to the local .envrc.
envrc() {
  # --- CONFIGURATION ---
  # Set this to the path where your flake wrapper projects are stored.
  local FLAKE_WRAPPERS_DIR="$HOME/projects/flake_wrappers"

  # Check if the source directory exists
  if [ ! -d "$FLAKE_WRAPPERS_DIR" ]; then
    echo "Error: Directory not found: $FLAKE_WRAPPERS_DIR" >&2
    echo "Please configure the FLAKE_WRAPPERS_DIR variable in the import_envrc function." >&2
    return 1
  fi

  # Find all subdirectories that contain a .envrc file.
  # -mindepth 1 and -maxdepth 1 ensure we only search the immediate children.
  # The `-exec test -f {}/.envrc \;` part checks for the existence of the file.
  # We use `fzf` to create an interactive menu.
  # The --preview shows the content of the .envrc file for the highlighted entry.
  # `bat` is used for preview if available, otherwise it falls back to `cat`.
  local selected_dir=$(find "$FLAKE_WRAPPERS_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -f {}/.envrc \; -print | \
    fzf --prompt="Select a Flake Wrapper to import > " \
        --header="[CTRL-C or ESC to quit]" \
        --preview="([[ -x \"$(command -v bat)\" ]] && bat --color=always --plain {}/.envrc) || cat {}/.envrc" \
        --preview-window="right:60%:wrap")

  # If the user pressed ESC or CTRL-C, fzf returns an empty string.
  # The `[ -z "$selected_dir" ]` check handles this case.
  if [ -z "$selected_dir" ]; then
    echo "No selection made. Operation cancelled."
    return 1
  fi

  local source_envrc="$selected_dir/.envrc"

  # Check if the selected .envrc file is readable
  if [ ! -r "$source_envrc" ]; then
    echo "Error: Cannot read file: $source_envrc" >&2
    return 1
  fi

  # Append the contents of the selected .envrc to the local .envrc file.
  # The `>>` operator will create the file if it doesn't exist, or append if it does.
  # We add a newline before appending to ensure separation if the local file doesn't end with one.
  printf "\n# Imported from %s\n" "$source_envrc" >> ./.envrc
  cat "$source_envrc" >> ./.envrc

  echo "✅ Successfully appended '$source_envrc' to the local .envrc file."
  ndr
}
