# Bitwarden Desktop (Electron) user state: vault cache, settings,
# session, and the local biometrics master-key file.
#
# Note: biometric/OS-keyring unlock on Plasma additionally stores
# secrets in KWallet via libsecret. That state is persisted by the
# `de_plasma` shared set (via ~/.local/share + ~/.config KWallet
# dirs); if biometrics still re-enrolls after reboot, check that
# the KWallet directories under that set actually cover kwalletd.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [ ".config/Bitwarden" ];
    files = [ ];
  };
}
