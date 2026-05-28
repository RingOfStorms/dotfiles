{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.rage

    # `enc [-s] [-p PW | -f FILE] <path> [output]`
    # If <path> is a directory: tar+gzips, encrypts with rage (passphrase mode),
    #   default output name is `<basename>.tar.gz.age`.
    # If <path> is a regular file: encrypts the file bytes directly,
    #   default output name is `<basename>.age`.
    # Then removes the original source. By default uses plain `rm -rf`. Pass
    # `-s` / `--shred` to overwrite with `shred` first (slow, and only
    # meaningful on non-SSD / non-CoW filesystems).
    #
    # Non-interactive passphrase sources (in priority order):
    #   -p, --passphrase <pw>          passphrase on argv (visible in `ps`)
    #   -f, --passphrase-file <path>   read passphrase from file (use - for stdin)
    #   $ENC_PASSPHRASE                read passphrase from env var
    # If none are provided, rage prompts on the controlling tty as before.
    (pkgs.writeShellScriptBin "enc" ''
      set -euo pipefail
      shred_mode=0
      pw=""
      pw_set=0
      pw_file=""
      # Parse leading flags. Stop at first non-flag arg.
      while [ $# -gt 0 ]; do
        case "$1" in
          -s|--shred) shred_mode=1; shift ;;
          -p|--passphrase)
            if [ $# -lt 2 ]; then echo "enc: $1 requires an argument" >&2; exit 1; fi
            pw="$2"; pw_set=1; shift 2 ;;
          --passphrase=*) pw="''${1#*=}"; pw_set=1; shift ;;
          -f|--passphrase-file)
            if [ $# -lt 2 ]; then echo "enc: $1 requires an argument" >&2; exit 1; fi
            pw_file="$2"; shift 2 ;;
          --passphrase-file=*) pw_file="''${1#*=}"; shift ;;
          -h|--help)
            echo "usage: enc [-s|--shred] [-p PW | -f FILE] <path> [output]" >&2
            echo "  dir  input -> default output <basename>.tar.gz.age (tar+gzip then encrypt)" >&2
            echo "  file input -> default output <basename>.age (encrypt bytes directly)" >&2
            echo "  -s, --shred              overwrite source with shred before removing (slow)" >&2
            echo "  -p, --passphrase PW      passphrase on argv (visible in ps)" >&2
            echo "  -f, --passphrase-file F  read passphrase from file ('-' for stdin)" >&2
            echo "  \$ENC_PASSPHRASE          fallback env var for passphrase" >&2
            exit 0 ;;
          --) shift; break ;;
          -*) echo "enc: unknown flag '$1'" >&2; exit 1 ;;
          *) break ;;
        esac
      done
      if [ $# -lt 1 ]; then
        echo "usage: enc [-s|--shred] [-p PW | -f FILE] <path> [output]" >&2
        exit 1
      fi

      # Resolve passphrase from -f / env if -p wasn't given.
      if [ $pw_set -eq 0 ] && [ -n "$pw_file" ]; then
        if [ "$pw_file" = "-" ]; then
          pw="$(cat)"
        else
          pw="$(cat -- "$pw_file")"
        fi
        # Strip a single trailing newline (common in files / `echo > file`).
        pw="''${pw%$'\n'}"
        pw_set=1
      fi
      if [ $pw_set -eq 0 ] && [ -n "''${ENC_PASSPHRASE:-}" ]; then
        pw="$ENC_PASSPHRASE"
        pw_set=1
      fi
      src="$1"
      if [ ! -e "$src" ]; then
        echo "enc: '$src' does not exist" >&2
        exit 1
      fi
      # Strip trailing slash so basename works on dirs like foo/
      src="''${src%/}"
      # Pick mode + default output name based on what $src is:
      #   directory      -> tar+gzip then encrypt, default <name>.tar.gz.age
      #   regular file   -> encrypt the bytes directly, default <name>.age
      # Symlinks are followed (-e). Anything else (socket/fifo/dev) is rejected.
      if [ -d "$src" ]; then
        mode=dir
        default_out="$(basename "$src").tar.gz.age"
      elif [ -f "$src" ]; then
        mode=file
        default_out="$(basename "$src").age"
      else
        echo "enc: '$src' is neither a regular file nor a directory" >&2
        exit 1
      fi
      out="''${2:-$default_out}"
      if [ -e "$out" ]; then
        echo "enc: refusing to overwrite existing '$out'" >&2
        exit 1
      fi
      parent="$(cd "$(dirname -- "$src")" && pwd)"
      name="$(basename -- "$src")"
      echo "enc: $src ($mode) -> $out" >&2
      # Pick the producer side of the pipeline based on mode.
      if [ "$mode" = dir ]; then
        produce() { tar -czf - -C "$parent" "$name"; }
      else
        produce() { cat -- "$src"; }
      fi
      if [ $pw_set -eq 1 ]; then
        # rage uses the `pinentry` crate, which spawns a `pinentry` binary
        # from $PATH and speaks the Assuan protocol over its stdio. We drop
        # a tiny Assuan-speaking shell script into a tempdir, prepend it to
        # $PATH, and hand it the passphrase via env var. This avoids both
        # `expect` and any extra dependencies.
        pe_dir="$(mktemp -d)"
        trap 'rm -rf -- "$pe_dir"' EXIT
        # Heredoc is single-quoted (no shell expansion) and unindented so
        # the shebang lands at column 0. The inner script reads the
        # passphrase from $ENC_PINENTRY_PW at runtime.
        cat > "$pe_dir/pinentry" <<'PINENTRY_EOF'
      #!${pkgs.bash}/bin/bash
      printf 'OK Pleased to meet you\n'
      while IFS= read -r line; do
        line="''${line%$'\r'}"
        case "$line" in
          GETPIN*)
            esc="''${ENC_PINENTRY_PW//%/%25}"
            printf 'D %s\n' "$esc"
            printf 'OK\n'
            ;;
          BYE*) printf 'OK closing connection\n'; exit 0 ;;
          *)    printf 'OK\n' ;;
        esac
      done
      PINENTRY_EOF
        chmod +x "$pe_dir/pinentry"
        export ENC_PINENTRY_PW="$pw"
        export PATH="$pe_dir:$PATH"
        export PINENTRY_PROGRAM="$pe_dir/pinentry"
        produce | ${pkgs.rage}/bin/rage -p -o "$out"
        unset ENC_PINENTRY_PW
      else
        produce | ${pkgs.rage}/bin/rage -p -o "$out"
      fi
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

    # `dec <file.age> [output]`
    # Decrypts (prompts for passphrase) and either:
    #   - extracts the tar.gz, if the input ends in `.tar.gz.age` or `.tgz.age`
    #     (output is treated as a target directory, default `.`)
    #   - writes raw decrypted bytes to a file otherwise
    #     (output is a file path; if it's an existing directory, the file is
    #      written inside it; default is `<basename-without-.age>` in cwd)
    # Force a mode with `--tar` / `--no-tar`.
    (pkgs.writeShellScriptBin "dec" ''
      set -euo pipefail
      force_mode=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --tar)    force_mode=tar; shift ;;
          --no-tar) force_mode=file; shift ;;
          -h|--help)
            echo "usage: dec [--tar|--no-tar] <file.age> [output]" >&2
            echo "  auto: *.tar.gz.age / *.tgz.age -> extract tar into [output] dir (default .)" >&2
            echo "        otherwise               -> write bytes to [output] file (default <basename minus .age>)" >&2
            exit 0 ;;
          --) shift; break ;;
          -*) echo "dec: unknown flag '$1'" >&2; exit 1 ;;
          *) break ;;
        esac
      done
      if [ $# -lt 1 ]; then
        echo "usage: dec [--tar|--no-tar] <file.age> [output]" >&2
        exit 1
      fi
      src="$1"
      if [ ! -f "$src" ]; then
        echo "dec: '$src' is not a file" >&2
        exit 1
      fi
      base="$(basename -- "$src")"
      # Detect mode from filename unless overridden.
      if [ -n "$force_mode" ]; then
        mode="$force_mode"
      else
        case "$base" in
          *.tar.gz.age|*.tgz.age) mode=tar ;;
          *)                       mode=file ;;
        esac
      fi
      if [ "$mode" = tar ]; then
        outdir="''${2:-.}"
        mkdir -p "$outdir"
        echo "dec: $src (tar) -> $outdir/" >&2
        ${pkgs.rage}/bin/rage -d "$src" \
          | tar -xzf - -C "$outdir"
        echo "dec: extracted into $outdir/" >&2
      else
        # Strip a trailing `.age` to get the default output filename.
        default_name="''${base%.age}"
        if [ "$default_name" = "$base" ]; then
          # Input didn't end in .age; append `.dec` to avoid clobbering.
          default_name="$base.dec"
        fi
        outarg="''${2:-}"
        if [ -z "$outarg" ]; then
          outpath="./$default_name"
        elif [ -d "$outarg" ]; then
          outpath="''${outarg%/}/$default_name"
        else
          outpath="$outarg"
        fi
        if [ -e "$outpath" ]; then
          echo "dec: refusing to overwrite existing '$outpath'" >&2
          exit 1
        fi
        echo "dec: $src (file) -> $outpath" >&2
        ${pkgs.rage}/bin/rage -d -o "$outpath" "$src"
        echo "dec: wrote $outpath" >&2
      fi
    '')
  ];
}
