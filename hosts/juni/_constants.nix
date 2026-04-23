# Service constants for juni (Framework 12 Laptop)
# Primarily a desktop with impermanence. Minimal services.
{
  host = {
    name = "juni";
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
    "rustdesk_server_key" = {
      kvPath = "kv/data/machines/low-trust/rustdesk_server_key";
      softDepend = [ "rustdesk" ];
    };
    "rustdesk_password" = {
      kvPath = "kv/data/machines/low-trust/rustdesk_password";
      softDepend = [ "rustdesk" ];
    };
  };
}
