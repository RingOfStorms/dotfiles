{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.rage

    # `enc [-s] <path> [output.tar.gz.age]`
    # Tar+gzips the path, encrypts with rage in passphrase mode, then
    # removes the original source. By default uses plain `rm -rf`. Pass
    # `-s` / `--shred` to overwrite with `shred` first (slow, and only
    # meaningful on non-SSD / non-CoW filesystems).
    (pkgs.writeShellScriptBin "enc" ''
      set -euo pipefail
      shred_mode=0
      # Parse leading flags. Stop at first non-flag arg.
      while [ $# -gt 0 ]; do
        case "$1" in
          -s|--shred) shred_mode=1; shift ;;
          -h|--help)
            echo "usage: enc [-s|--shred] <path> [output.tar.gz.age]" >&2
            echo "  -s, --shred   overwrite source with shred before removing (slow)" >&2
            exit 0 ;;
          --) shift; break ;;
          -*) echo "enc: unknown flag '$1'" >&2; exit 1 ;;
          *) break ;;
        esac
      done
      if [ $# -lt 1 ]; then
        echo "usage: enc [-s|--shred] <path> [output.tar.gz.age]" >&2
        exit 1
      fi
      src="$1"
      if [ ! -e "$src" ]; then
        echo "enc: '$src' does not exist" >&2
        exit 1
      fi
      # Strip trailing slash so basename works on dirs like foo/
      src="''${src%/}"
      out="''${2:-$(basename "$src").tar.gz.age}"
      if [ -e "$out" ]; then
        echo "enc: refusing to overwrite existing '$out'" >&2
        exit 1
      fi
      parent="$(cd "$(dirname -- "$src")" && pwd)"
      name="$(basename -- "$src")"
      echo "enc: $src -> $out" >&2
      tar -czf - -C "$parent" "$name" \
        | ${pkgs.rage}/bin/rage -p -o "$out"
      echo "enc: wrote $out" >&2

      # Remove the original source now that the encrypted archive exists.
      if [ $shred_mode -eq 1 ]; then
        # NOTE: shred is mostly security theater on SSDs and CoW filesystems
        # (btrfs/zfs/bcachefs) due to wear leveling and copy-on-write. It is
        # only meaningfully effective on traditional spinning disks with
        # non-journaled overwrites. Use FDE for real unrecoverability.
        echo "enc: shredding + removing $src (this may be slow)" >&2
        if [ -d "$src" ]; then
          # Many files (e.g. git pack/object files) are mode 0444 and shred
          # needs to open them for writing. Grant owner write on the tree.
          chmod -R u+w -- "$src" 2>/dev/null || true
          ${pkgs.findutils}/bin/find "$src" -type f -print0 \
            | xargs -0 -r ${pkgs.coreutils}/bin/shred -u -n 3 -z
          rm -rf -- "$src"
        else
          chmod u+w -- "$src" 2>/dev/null || true
          ${pkgs.coreutils}/bin/shred -u -n 3 -z -- "$src"
        fi
      else
        echo "enc: removing $src" >&2
        chmod -R u+w -- "$src" 2>/dev/null || true
        rm -rf -- "$src"
      fi
      echo "enc: removed $src" >&2
    '')

    # `dec <file.tar.gz.age> [output-dir]`
    # Decrypts (prompts for passphrase) and extracts the tar.gz.
    (pkgs.writeShellScriptBin "dec" ''
      set -euo pipefail
      if [ $# -lt 1 ]; then
        echo "usage: dec <file.tar.gz.age> [output-dir]" >&2
        exit 1
      fi
      src="$1"
      if [ ! -f "$src" ]; then
        echo "dec: '$src' is not a file" >&2
        exit 1
      fi
      outdir="''${2:-.}"
      mkdir -p "$outdir"
      echo "dec: $src -> $outdir/" >&2
      ${pkgs.rage}/bin/rage -d "$src" \
        | tar -xzf - -C "$outdir"
      echo "dec: extracted into $outdir/" >&2
    '')
  ];
}
