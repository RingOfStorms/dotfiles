required settings?

- nixpkgs and home manager flake inputs

```nix
# Required system information
system.stateVersion = "ORIGINAL VALUE"
networking.hostName = "system_name";

# Where this config lives for this machine
programs.nh.flake = "/home/josh/.config/nixos-config/hosts/${config.networking.hostName}";

# Optionally allow unfree software
nixpkgs.config.allowUnfree = true;

users.users = {
    josh = {
        isNormalUser = true;
        initialPassword = "password1";
        extraGroups = [ "wheel" "networkmanager" "video" "input" ];
        openssh.authorizedKeys.keys = [ "replace" ];
    };
};

# Home manager only below this line (optional)
security.polkit.enable = true;
home-manager = {
    useUserPackages = true;
    useGlobalPkgs = true;
    backupFileExtension = "bak";
    sharedModules = [
        ({}: {
            home.stateVersion = "MATCH_HM_VERSION_AS_INPUT";
            programs.home-manager.enable = true;
        })
    ];
};
```

# TODO add somewhere

```nix



 # allow mounting ntfs filesystems
  boot.supportedFilesystems = [ "ntfs" ];

  # make shutdown faster for waiting
  systemd.extraConfig = ''
    DefaultTimeoutStopSec=8s
  '';

 nix.settings = {
    substituters = [
      "https://hyprland.cachix.org"
      "https://cosmic.cachix.org/"
    ];
    trusted-substituters = config.nix.settings.substituters;
    trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE="
    ];
 };

services.tailscale.extraUpFlags = ++ (lib.optionals cfg.enableExitNode [ "--advertise-exit-node" ]);

```

# TODO

- New reporting for machine stats
- programs not ported, yet
  - rust dev (now using direnv local flakes for that)
  - incus
  - virt-manager
- hm not ported
  - obs
- opensnitch
  - homemanager `services.opensnitch-ui.enable = true;`
- hyprland config
- i3 isntead of sway?
