{
  host = {
    name = "oren";
    overlayIp = "100.64.0.5";
    primaryUser = "josh";
    stateVersion = "25.11";
  };

  services = { };

  secrets = {
    "atuin-key-josh_2026-03-15" = {
      owner = "josh";
      group = "users";
      mode = "0400";
      hardDepend = [ "atuin-autologin" ];
      template = ''{{- with secret "kv/data/machines/high-trust/atuin-key-josh_2026-03-15" -}}{{ printf "%s\n%s\n%s" .Data.data.user .Data.data.password .Data.data.value }}{{- end -}}'';
    };
  };
}
