{
  ...
}:
{
  options = { };

  config = {
    # Random test, visit http://192.168.100.11/
    containers.wasabi = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      hostAddress = "192.168.100.2";
      localAddress = "192.168.100.11";
      config =
        { config, pkgs, ... }:
        {
          system.stateVersion = "24.11";
          services.httpd.enable = true;
          services.httpd.adminAddr = "foo@example.org";
          networking.firewall = {
            enable = true;
            allowedTCPPorts = [ 80 ];
          };
        };
    };

    virtualisation.oci-containers.containers = {
      # Example of defining a container, visit http://localhost:8085/
      "nginx_simple" = {
        # autoStart = true; this is default true
        image = "nginx:latest";
        ports = [
          "127.0.0.1:8085:80"
        ];
      };
    };
  };
}
