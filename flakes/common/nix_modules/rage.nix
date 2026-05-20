{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.rage

    # `enc <path> [output.tar.gz.age]`
    # Tar+gzips the path, encrypts with rage in passphrase mode, then
    # securely shreds + removes the original source.
    (pkgs.writeShellScriptBin "enc" ''
      set -euo pipefail
      if [ $# -lt 1 ]; then
        echo "usage: enc <path> [output.tar.gz.age]" >&2
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

      # Securely shred + remove the original source now that the
      # encrypted archive exists. shred only meaningfully helps on
      # traditional filesystems (not CoW/SSD-with-wear-leveling),
      # but we still overwrite to make casual recovery harder.
      echo "enc: securely removing $src" >&2
      if [ -d "$src" ]; then
        ${pkgs.findutils}/bin/find "$src" -type f -print0 \
          | xargs -0 -r ${pkgs.coreutils}/bin/shred -u -n 3 -z
        rm -rf -- "$src"
      else
        ${pkgs.coreutils}/bin/shred -u -n 3 -z -- "$src"
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
