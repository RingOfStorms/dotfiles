# Shared persistence sets

Each `.nix` file in this directory evaluates to an attrset of the form:

```nix
{
  system = {
    directories = [ /* absolute paths */ ];
    files       = [ /* absolute paths */ ];
  };
  user = {
    directories = [ /* paths relative to $HOME */ ];
    files       = [ /* paths relative to $HOME */ ];
  };
}
```

All four arrays must always be present (use `[ ]` if a set has no entries
in some category). This invariant lets consumers (host `impermanence.nix`
files) merge sets together with simple list concatenation and no
attribute-existence checks.

## Adding a new set

1. Create a new `<name>.nix` here. Keep it scoped to one logical
   app/concept (atuin, bluetooth, plasma, etc.) — fine-grained sets
   compose better than broad ones.
2. The file is auto-discovered and exposed as
   `inputs.impermanence_mod.sharedPersistence.<name>` (see
   `../flake.nix`).
3. Reference it from a host's `impermanence.nix` via the
   `mergeSharedPersistence` helper, also exposed by the flake.

## Anti-patterns

- Don't persist files that get atomically rewritten (KDE *rc files,
  many GTK config files). The bind mount detaches and the persisted
  copy goes stale. Persist the parent directory instead, or accept
  loss on reboot. See `de_plasma.nix` for the relevant comment.
- Don't persist anything that the NixOS module system writes
  declaratively (e.g. /etc/ssh/sshd_config). Bind-mounting hides the
  generated file.
