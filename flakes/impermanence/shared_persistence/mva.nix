# mva (Minimal Viable Agent) CLI: profile config, on-disk caches,
# and per-session state. Paths mirror the writable allow-list in the
# nono `mva` profile (~/.config/nono/profiles/mva.json), so anything
# the agent is allowed to mutate also survives reboot.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [
      ".config/mva"
      ".cache/mva"
      ".local/share/mva"
    ];
    files = [ ];
  };
}
