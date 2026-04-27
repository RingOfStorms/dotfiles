# NetworkManager: saved Wi-Fi connections, secrets, and runtime state.
{
  system = {
    directories = [
      "/etc/NetworkManager/system-connections"
      "/var/lib/NetworkManager"
    ];
    files = [ ];
  };
  user = {
    directories = [ ];
    files = [ ];
  };
}
