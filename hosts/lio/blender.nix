# Blender (ROCm/HIP) + the official Blender Lab MCP server/add-on, fully declarative.
#
#  - `blender`      : pkgsRocm.blender wrapped so the MCP add-on ships as a read-only
#                     system extension (bl_ext.system.mcp), is auto-enabled on startup,
#                     and online access is on (the add-on refuses to start its TCP
#                     bridge otherwise). The bridge listens on 127.0.0.1:9876.
#  - `blender-mcp`  : stdio MCP server the AI client spawns; it talks to the bridge.
#
# SECURITY: the add-on executes LLM-generated Python inside the Blender process with
# Blender's full user privileges (files, network). Sandboxing the AI client does not
# constrain that code; only isolating Blender itself (or the whole setup in a VM) does.
{ pkgs, lib, ... }:
let
  version = "1.0.3";
  src = pkgs.fetchgit {
    url = "https://projects.blender.org/lab/blender_mcp.git";
    rev = "v${version}";
    hash = "sha256-pYeByO4Oi5eyynsJhGVd1vBWXHvhGn+Y5LGit6Kazlw=";
  };

  blenderMcpServer = pkgs.python3Packages.buildPythonApplication {
    pname = "blender-mcp";
    inherit version src;
    pyproject = true;
    sourceRoot = "${src.name}/mcp";
    build-system = [ pkgs.python3Packages.setuptools ];
    dependencies =
      with pkgs.python3Packages;
      [
        docutils
        mcp
        pyyaml
      ]
      ++ mcp.optional-dependencies.cli or [ ];
    pythonImportsCheck = [ "blmcp" ];
    meta = {
      description = "Official Blender Lab MCP server";
      homepage = "https://www.blender.org/lab/mcp-server/";
      license = lib.licenses.gpl3Plus;
      mainProgram = "blender-mcp";
    };
  };

  # $BLENDER_SYSTEM_EXTENSIONS/<repo>/<extension-id>; repo "system" => module bl_ext.system.mcp
  systemExtensions = pkgs.runCommand "blender-system-extensions" { } ''
    mkdir -p $out/system
    cp -r ${src}/addon/blender_mcp_addon $out/system/mcp
  '';

  blender = pkgs.symlinkJoin {
    name = "blender-mcp-wrapped-${pkgs.pkgsRocm.blender.version}";
    paths = [ pkgs.pkgsRocm.blender ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      # --addons enables the extension for this session (not saved to userpref).
      wrapProgram $out/bin/blender \
        --set BLENDER_SYSTEM_EXTENSIONS ${systemExtensions} \
        --add-flags "--online-mode --addons bl_ext.system.mcp"
    '';
    inherit (pkgs.pkgsRocm.blender) meta;
  };
  mcpCommand = lib.getExe blenderMcpServer;

  # Esfor ai3d (Tripo3D image-to-3D). The API key is a runtime secret: it is read from
  # ~/.config/esfor/tripo_api_key (mode 0600) when the wrapper runs and is exported only
  # to the wrapped command. It never enters the Nix store or the global environment.
  # Usage: tripo-env ai3d balance   |   tripo-env <cmd> ...
  tripoEnv = pkgs.writeShellApplication {
    name = "tripo-env";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      key_file="''${TRIPO_API_KEY_FILE:-$HOME/.config/esfor/tripo_api_key}"
      if [ -z "''${TRIPO_API_KEY:-}" ]; then
        if [ ! -r "$key_file" ]; then
          echo "tripo-env: $key_file not found (create it with chmod 600)" >&2
          exit 1
        fi
        mode="$(stat -c %a "$key_file")"
        if [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
          echo "tripo-env: $key_file must be mode 0600 (is $mode)" >&2
          exit 1
        fi
        TRIPO_API_KEY="$(tr -d '[:space:]' < "$key_file")"
        export TRIPO_API_KEY
      fi
      if [ "$#" -eq 0 ]; then
        echo "usage: tripo-env <command> [args...]" >&2
        exit 2
      fi
      exec "$@"
    '';
  };

  # `ai3d` on PATH: runs the repo's tools/ai3d (stdlib-only Python) from the current checkout.
  ai3dCli = pkgs.writeShellApplication {
    name = "ai3d";
    runtimeInputs = [ pkgs.python3 pkgs.git ];
    text = ''
      root="''${ESFOR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/projects/esfor")}"
      exec python3 "$root/tools/ai3d/ai3d.py" "$@"
    '';
  };
in
{
  environment.systemPackages = [
    blender
    blenderMcpServer
    tripoEnv
    ai3dCli
    # Mesh cleanup / inspection for ai3d outputs. Instant Meshes is not packaged in
    # nixpkgs (26.05 or unstable); quad remeshing uses Blender's QuadriFlow until it is.
    pkgs.meshlab
  ];

  # opencode merges $OPENCODE_CONFIG over ~/.config/opencode/opencode.json, so the
  # user's own (stateful) config stays untouched.
  environment.variables.OPENCODE_CONFIG = toString (
    pkgs.writeText "opencode-blender-mcp.json" (
      builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        mcp.blender = {
          type = "local";
          command = [ mcpCommand ];
          enabled = true;
        };
      }
    )
  );

  # omp user-level MCP config. Read-only symlink: manage servers here, not via `/mcp add`.
  home-manager.users.josh.home.file.".omp/agent/mcp.json".text = builtins.toJSON {
    mcpServers.blender = {
      command = mcpCommand;
      args = [ ];
    };
  };
}
