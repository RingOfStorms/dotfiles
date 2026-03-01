{
  constants,
  ...
}:
let
  rd = constants.services.rustdesk;
  TailscaleInterface = "tailscale0";
  TCPPorts = [
    rd.ports.signal
    rd.ports.relay
    rd.ports.relayHbbs
    rd.ports.tcp4
    rd.ports.tcp5
  ];
  UDPPorts = [ rd.ports.relay ];
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
