{
  host = {
    name = "joe";
    overlayIp = "100.64.0.12";
    primaryUser = "josh";
    stateVersion = "26.05";
  };

  services = {
    llama-cpp = {
      port = 11434;
    };
    kokoro-tts = {
      port = 8880;
      dataDir = "/var/lib/kokoro-tts";
    };
    forge = {
      port = 7860;
      dataDir = "/var/lib/forge";
    };
    homepage = {
      port = 8082;
    };
    # xrdp — RDP server (fresh-session model, X11). Authenticates via
    # PAM against the user's system password; no openbao password
    # needed for the RDP server itself.
    xrdp = {
      port = 3389;
    };
  };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  # xrdp authenticates via PAM against the user's system password,
  # so no openbao secret is needed for the RDP server.
  #
  # NOTE: When Guacamole connects to joe via RDP, it'll need the user's
  # actual system password, which it will get from the Guacamole
  # connection config on h001 (machines/high-trust/guacamole_joe_*).
  # That secret should be set to josh's plaintext system password so
  # the Guacamole connection succeeds via PAM.
  secrets = { };
}
