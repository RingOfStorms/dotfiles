{ lib, pkgs, ... }:
let
  # Exact descriptions as reported by: hyprctl -j monitors | jq '.[].description'
  mainDesc = "ASUSTek COMPUTER INC ASUS PG43U 0x01010101";
  secondaryDesc = "Samsung Electric Company C34J79x HTRM900776";

  mainMonitor = "desc:${mainDesc}";
  secondaryMonitor = "desc:${secondaryDesc}";

  hyprlandExtraOptions = {
    exec-once = [
      # Wait a moment for monitors/workspaces to settle, then "prime" 6 and return to 1
      "sh -lc 'sleep 0.2; hyprctl dispatch workspace 7; sleep 0.02; hyprctl dispatch workspace 1'"

    ];
    monitor = [
      "${mainMonitor},3840x2160@97.98,0x0,1,transform,0"
      "${secondaryMonitor},3440x1440@99.98,-1440x-640,1,transform,1"
    ];
    workspace =
      let
        inherit (builtins) map toString;
        inherit (lib) range;
        mkWs = monitor: i: "${toString i},monitor:${monitor},persistent:true";
      in
      (map (mkWs mainMonitor) (range 1 6)) ++ (map (mkWs secondaryMonitor) (range 7 10));
  };

  moveScript = pkgs.writeShellScriptBin "hyprland-move-workspaces" ''
    #!/usr/bin/env bash
    set -euo pipefail

    HYPRCTL='${pkgs.hyprland}/bin/hyprctl'
    JQ='${pkgs.jq}/bin/jq'
    SOCAT='${pkgs.socat}/bin/socat'

    MAIN_DESC='${mainDesc}'
    SEC_DESC='${secondaryDesc}'

    get_socket() {
      # socket2 carries the event stream
      echo "${"$"}{XDG_RUNTIME_DIR}/hypr/${"$"}{HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
    }

    wait_for_hypr() {
      # Wait until hyprctl works (Hyprland is up)
      until ''${HYPRCTL} -j monitors >/dev/null 2>&1; do
        sleep 0.5
      done
    }

    mon_name_by_desc() {
      # Resolve Hyprland "name" (e.g., DP-2) from human-friendly description
      local desc="${"$"}1"
      ''${HYPRCTL} -j monitors \
        | ''${JQ} -r --arg d "${"$"}desc" '.[] | select(.description == $d) | .name' \
        | head -n1
    }

    place_workspaces() {
      local mainName secName
      mainName="$(mon_name_by_desc "${"$"}MAIN_DESC")"
      secName="$(mon_name_by_desc "${"$"}SEC_DESC" || true)"

      # Always keep 1–6 on the main monitor
      for ws in 1 2 3 4 5 6; do
        ''${HYPRCTL} dispatch moveworkspacetomonitor "${"$"}ws" "${"$"}mainName" || true
      done

      if [ -n "${"$"}{secName:-}" ]; then
        # Secondary is present ➜ put 7–10 on secondary
        for ws in 7 8 9 10; do
          ''${HYPRCTL} dispatch moveworkspacetomonitor "${"$"}ws" "${"$"}secName" || true
        done
      else
        # No secondary ➜ keep 7–10 on main
        for ws in 7 8 9 10; do
          ''${HYPRCTL} dispatch moveworkspacetomonitor "${"$"}ws" "${"$"}mainName" || true
        done
      fi
    }

    watch_events() {
      local sock
      sock="$(get_socket)"

      # If socket2 is missing for some reason, fall back to polling
      if [ ! -S "${"$"}sock" ]; then
        while :; do
          place_workspaces
          sleep 5
        done
        return
      fi

      # Subscribe to Hyprland events and react to monitor changes
      ''${SOCAT} - "UNIX-CONNECT:${"$"}sock" | while IFS= read -r line; do
        case "${"$"}line" in
          monitoradded*|monitorremoved*|activemonitor*|layoutchange*|createworkspace*)
            place_workspaces
          ;;
        esac
      done
    }

    if [ "${"$"}{1:-}" = "--oneshot" ]; then
      wait_for_hypr
      place_workspaces
    else
      wait_for_hypr
      place_workspaces
      watch_events
    fi
  '';
in
{
  options = { };

  config = {
    environment.systemPackages = [ moveScript ];

    ringofstorms_common.desktopEnvironment.hyprland.extraOptions = hyprlandExtraOptions;

    # User-level systemd service that follows your Hyprland session and watches for monitor changes
    # systemd.user.services.hyprland-move-workspaces = {
    #   description = "Keep workspaces 1–6 on main and 7–10 on secondary; react to monitor changes";
    #
    #   # Start/stop with Hyprland specifically
    #   wantedBy = [ "hyprland-session.target" ];
    #   after = [ "hyprland-session.target" ];
    #   partOf = [ "hyprland-session.target" ];
    #   bindsTo = [ "hyprland-session.target" ];
    #   # Only start once Hyprland's event socket exists
    #   unitConfig.ConditionPathExistsGlob = "%t/hypr/*/.socket2.sock";
    #
    #   serviceConfig = {
    #     Type = "simple";
    #     ExecStart = "${moveScript}/bin/hyprland-move-workspaces";
    #     Restart = "always";
    #     RestartSec = "2s";
    #   };
    # };
  };
}
