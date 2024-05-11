{ lib, ylib, settings, ... }:
{
  imports =
    [ ]
    ## Common nix modules
    ++ ylib.umport {
      path = lib.fileset.maybeMissing (settings.usersDir + "/_common/nix_modules");
      recursive = true;
    }
    # Nix modules for this user
    ++ ylib.umport {
      path = lib.fileset.maybeMissing ./nix_modules;
      recursive = true;
    }
    # Nix modules by host for this user
    ++ ylib.umport {
      path = lib.fileset.maybeMissing ./by_hosts/${settings.system.hostname}/nix_modules;
      recursive = true;
    };

  home-manager.users.${settings.user.username} = {
    imports =
      [ ]
      # Common home manager
      ++ ylib.umport {
        path = lib.fileset.maybeMissing (settings.usersDir + "/_common/home_manager");
        recursive = true;
      }
      # Home manger for this user
      ++ ylib.umport {
        path = lib.fileset.maybeMissing ./home_manager;
        recursive = true;
      }
      # Home manager by host for this user
      ++ ylib.umport {
        path = lib.fileset.maybeMissing ./by_hosts/${settings.system.hostname}/home_manager;
        recursive = true;
      };
  };
} 


