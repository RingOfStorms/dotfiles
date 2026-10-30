# Full-rate tensor cores on joe's RTX 3080 (gpu-unlock).
#
# GeForce Ampere issues FP16/BF16/TF32 MMA with FP32 accumulation at half the
# rate of the same silicon sold as RTX A-series. Zagitta/gpu-unlock rewrites
# the speed selectors and resets the card before `nvidia` binds it. No driver
# patch or VBIOS flash; the stock driver then runs as usual. Helps LocalAI's
# FP16/BF16 diffusion and prompt processing; quantized decode and games are
# unchanged.
#
# Upstream: https://github.com/Zagitta/gpu-unlock (README: boot flow, opt-in).
#
# Boot order matters: joe force-loads nvidia from the initrd
# (configuration.nix boot.initrd.kernelModules, i.e. systemd-modules-load),
# and udev coldplug would load it by modalias too. The initrd unit below runs
# `modprobe gpu_unlock` before both; the module's init waits until the unlock
# has finished. Firmware reaches the initrd through the module's
# MODULE_FIRMWARE entries (makeModulesClosure + hardware.firmware).
#
# The NVIDIA 610.43.03 archives are only build inputs for the firmware the
# unlock runs; joe's own driver version is independent of them.
#
# Recovery: delete `gpu_unlock.targets=` in the systemd-boot editor (`e`) or
# boot an older generation. If the card's firmware hung, power the machine
# fully off first (upstream keeps its DMA buffers until power-off); a warm
# reboot is not enough.
{ config, pkgs, ... }:
let
  version = "2.0.0";
  nvVersion = "610.43.03";

  # joe's only GPU (`/sys/bus/pci/devices`, 10de:2206). An address that is not
  # a supported, unbound card is logged and ignored.
  target = "0000:01:00.0";

  src = pkgs.fetchFromGitHub {
    owner = "Zagitta";
    repo = "gpu-unlock";
    rev = "7eb51bccae0a0b7e599e084d971170e9a1e82d0c"; # VERSION 2.0.0
    hash = "sha256-1KD/J1S1uyI5GGoTwQ1cU/sXeEKlG54exSvi6U+j73M=";
  };

  # Hashes from upstream packaging/arch/PKGBUILD.
  nvSource = pkgs.fetchurl {
    url = "https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-${nvVersion}.tar.xz";
    hash = "sha256-fhGJI8eiPtw2EU1jJzpG4+BOmvmGlaQiA+esLf6fwdw=";
  };
  nvInstaller = pkgs.fetchurl {
    url = "https://download.nvidia.com/XFree86/Linux-x86_64/${nvVersion}/NVIDIA-Linux-x86_64-${nvVersion}-no-compat32.run";
    hash = "sha256-4IRFHbcwpt8p09dPZVdJxNI248lF99lLUgXoQxj+L5A=";
  };

  # Extracted by upstream's own scripts; the installer is read, never run.
  firmware = pkgs.stdenvNoCC.mkDerivation {
    pname = "gpu-unlock-firmware";
    version = "${version}-${nvVersion}";
    inherit src;
    nativeBuildInputs = [
      pkgs.python3
      pkgs.zstd
    ];
    buildPhase = ''
      runHook preBuild
      tar -xf ${nvSource}
      python3 firmware/extract_gsp.py ${nvInstaller} assets
      python3 firmware/extract_boot_assets.py NVIDIA-kernel-module-source-${nvVersion} assets
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      make install-firmware DESTDIR=$out ASSETS=$PWD/assets \
        FWDIR=/lib/firmware/gpu-unlock/${nvVersion} LICENSEDIR=/share/licenses
      runHook postInstall
    '';
    # The GSP images are ELF; stripping or patching them would corrupt them.
    dontFixup = true;
  };

  module = config.boot.kernelPackages.callPackage (
    {
      stdenv,
      kernel,
      kernelModuleMakeFlags,
    }:
    stdenv.mkDerivation {
      pname = "gpu-unlock";
      version = "${version}-${kernel.version}";
      inherit src;
      sourceRoot = "${src.name}/kernel/gpu_unlock";
      nativeBuildInputs = kernel.moduleBuildDependencies;
      hardeningDisable = [ "pic" ];
      makeFlags = kernelModuleMakeFlags ++ [
        "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      ];
      installPhase = ''
        runHook preInstall
        install -Dm444 gpu_unlock.ko $out/lib/modules/${kernel.modDirVersion}/extra/gpu_unlock.ko
        runHook postInstall
      '';
    }
  ) { };
in
{
  hardware.firmware = [ firmware ];
  boot.extraModulePackages = [ module ];
  boot.initrd.availableKernelModules = [ "gpu_unlock" ];

  # The module does nothing without this.
  boot.kernelParams = [ "gpu_unlock.targets=${target}" ];

  boot.initrd.systemd.services.gpu-unlock = {
    description = "Unlock GeForce tensor-core rate before nvidia binds";
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "systemd-modules-load.service"
      "systemd-udevd.service"
      "systemd-udev-trigger.service"
    ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Failure only leaves the card locked; nvidia still loads after it.
      ExecStart = "${config.boot.initrd.systemd.package.kmod}/bin/modprobe gpu_unlock";
    };
  };
}
