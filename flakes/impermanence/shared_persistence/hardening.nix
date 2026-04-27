# State that the `hardening` common module produces. Mirrors the set
# of packages/services it installs:
# - fail2ban ban database (so attackers stay banned across reboots)
#
# If `hardening` ever grows new stateful services, persist them here so
# every host that imports `nixosModules.hardening` automatically picks
# them up via this set.
{
  system = {
    directories = [ "/var/lib/fail2ban" ];
    files = [ ];
  };
  user = {
    directories = [ ];
    files = [ ];
  };
}
