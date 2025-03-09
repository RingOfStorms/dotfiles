{ ... }:
{
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = false;
  networking.hostName = "o001";
  networking.domain = "subnet01171946.vcn01171946.oraclevcn.com";
  services.openssh.enable = true;
  system.stateVersion = "23.11";
}
