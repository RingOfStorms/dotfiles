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
    dependencies = with pkgs.python3Packages; [ docutils mcp pyyaml ] ++ mcp.optional-dependencies.cli or [ ];
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
in
{
  environment.systemPackages = [ blender blenderMcpServer ];

  # opencode merges $OPENCODE_CONFIG over ~/.config/opencode/opencode.json, so the
  # user's own (stateful) config stays untouched.
  environment.variables.OPENCODE_CONFIG = toString (pkgs.writeText "opencode-blender-mcp.json" (builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    mcp.blender = { type = "local"; command = [ mcpCommand ]; enabled = true; };
  }));

  # omp user-level MCP config. Read-only symlink: manage servers here, not via `/mcp add`.
  home-manager.users.josh.home.file.".omp/agent/mcp.json".text = builtins.toJSON {
    mcpServers.blender = { command = mcpCommand; args = [ ]; };
  };
}
