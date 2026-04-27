# Core OS state every host should persist.
#
# - /var/log: journal + service logs across boots
# - /var/lib/nixos: nixos-generated state (uid map, etc.)
# - /var/lib/systemd/{coredump,timers}: systemd state
# - /etc/nixos: legacy config dir (some tools still read it)
# - /machine-key.json: openbao machine identity (if used)
# - /etc/machine-id: stable machine id across boots
# - /etc/adjtime: hwclock drift correction
#
# User: ssh keys, gpg keyring, the projects scratch dir, and the
# nixos-config checkout itself (you really don't want to re-clone
# this on every boot).
{
  system = {
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/systemd/timers"
      "/etc/nixos"
    ];
    files = [
      "/machine-key.json"
      "/etc/machine-id"
      "/etc/adjtime"
    ];
  };
  user = {
    directories = [
      ".ssh"
      ".gnupg"
      "projects"
      ".config/nixos-config"
    ];
    files = [ ];
  };
}
