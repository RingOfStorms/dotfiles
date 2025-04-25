{
  ...
}:
let
  TailscaleInterface = "tailscale0";
  TCPPorts = [
    21115
    21116
    21117
    21118
    21119
  ];
  UDPPorts = [ 21116 ];
in
{
  services = {
    rustdesk-server = {
      enable = true;
      relay.enable = true;
      signal.enable = true;
      # Instead we only allow this on the tailnet IP range
      openFirewall = false;
      signal.relayHosts = [ "localhost" ];
    };
  };

  networking.firewall.interfaces."${TailscaleInterface}" = {
    allowedTCPPorts = TCPPorts;
    allowedUDPPorts = UDPPorts;
  };
}
