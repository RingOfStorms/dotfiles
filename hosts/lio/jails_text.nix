{
  config,
  pkgs,
  lib,
  ...
}:
{
  options = { };

  imports = [
  ];

  config = {
    environment.systemPackages = with pkgs; [
      firejail
    ];

    boot.kernelModules = [ "dummy" ];
    networking.interfaces.sandbox0 = {
      ipv4.addresses = [
        {
          address = "10.10.10.2";
          prefixLength = 24;
        }
      ];
    };
    networking.nftables.ruleset = ''
      table inet filter {
        chain input {
          type filter hook input priority 0;
          iifname "lo" accept
          iifname "sandbox0" ip saddr 93.184.216.34 accept
          drop
        }
        chain output {
          type filter hook output priority 0;
          oifname "lo" accept
          oifname "sandbox0" ip daddr 93.184.216.34 accept
          drop
        }
      }
    '';

    programs.firejail = {
      enable = true;
      wrappedBinaries = {
        jcurl = {
          executable = lib.getExe pkgs.curl;
          extraArgs = [
            "--quiet"
            "--noprofile"
            "--private"
            "--net=none"
            "--seccomp"
          ];
        };
        jbat = {
          executable = lib.getExe pkgs.bat;
          extraArgs = [
            "--quiet"
            "--noprofile"
            "--private"
            "--net=none"
            "--seccomp"
          ];
        };
      };
    };
  };
}
