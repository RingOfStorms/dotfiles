{ pkgs, ... }:
{
  ############################
  # Intel iGPU / VAAPI / QSV #
  ############################

  # Modern graphics stack
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      # VAAPI driver for Broadwell and newer (your 11th gen)
      intel-media-driver

      # OpenCL / compute; 11th gen typically works with the non-legacy runtime
      intel-ocl
      intel-compute-runtime

      # VPL runtime – needed for modern QSV on newer Intel (11th gen+)
      vpl-gpu-rt

      # VAAPI ⇔ VDPAU bridge (optional but harmless)
      libva-vdpau-driver
    ];
  };

  # Make sure the right VAAPI driver is used (iHD is correct for 11th gen)
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };

  # Optional but can help when services (like jellyfin) run in their own units
  systemd.services.jellyfin.environment.LIBVA_DRIVER_NAME = "iHD";

  ########################
  # Firmware for the iGPU
  ########################

  # Ensures i915 GuC/HuC firmware is available (avoids “GuC firmware … ENOENT” errors)
  hardware.enableAllFirmware = true;

  ########################
  # (Optional) debugging
  ########################

  environment.systemPackages = with pkgs; [
    libva-utils # vainfo
    intel-gpu-tools # intel_gpu_top
    clinfo # OpenCL info
  ];
}
