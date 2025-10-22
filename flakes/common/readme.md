# TODO add somewhere

```nix



 # allow mounting ntfs filesystems
  boot.supportedFilesystems = [ "ntfs" ];

  # make shutdown faster for waiting
  systemd.extraConfig = ''
    DefaultTimeoutStopSec=8s
  '';



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
