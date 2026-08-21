{
  description = "Reusable bcachefs impermanence module with encrypted subvolume layout, boot-time root reset, snapshot management tools, and a library of shared persistence sets that hosts can opt into.";

  inputs = {
    impermanence.url = "github:nix-community/impermanence";
    disko.url = "github:nix-community/disko/latest";
  };

  outputs = { impermanence, disko, ... }:
    let
      # ── Auto-import shared persistence sets ────────────────────────────
      # Every `*.nix` file under ./shared_persistence/ is loaded and
      # exposed as `outputs.sharedPersistence.<basename>`. Each file
      # MUST evaluate to:
      #   {
      #     system = { directories = [ ]; files = [ ]; };
      #     user   = { directories = [ ]; files = [ ]; };
      #   }
      # All four arrays are mandatory (use `[ ]` if empty) so the
      # `mergeSharedPersistence` helper below can concatenate without
      # attribute-existence checks.
      sharedDir = ./shared_persistence;
      sharedEntries = builtins.readDir sharedDir;
      sharedNames =
        builtins.filter
          (name:
            let
              entry = sharedEntries.${name};
              isNix = entry == "regular" && builtins.match ".*\\.nix$" name != null;
            in
            isNix
          )
          (builtins.attrNames sharedEntries);
      stripNix = name: builtins.elemAt (builtins.match "(.*)\\.nix$" name) 0;
      sharedPersistence =
        builtins.listToAttrs (
          map (name: {
            name = stripNix name;
            value = import (sharedDir + "/${name}");
          }) sharedNames
        );

      # ── Merge helper ───────────────────────────────────────────────────
      # Takes a list of shared-persistence sets (each shaped like the
      # files in ./shared_persistence/) and returns one merged set with
      # duplicates removed in each list. Hosts splat the result into
      # their own `environment.persistence."/persist"` block alongside
      # any host-specific entries.
      mergeSharedPersistence = sets:
        let
          concatUnique = lists:
            let
              # Tiny order-preserving unique. Avoids depending on
              # nixpkgs.lib here so the flake stays self-contained.
              go = acc: xs:
                if xs == [ ] then acc
                else
                  let
                    head = builtins.head xs;
                    tail = builtins.tail xs;
                  in
                  if builtins.elem head acc then go acc tail
                  else go (acc ++ [ head ]) tail;
            in
            go [ ] (builtins.concatLists lists);
        in
        {
          system = {
            directories = concatUnique (map (s: s.system.directories) sets);
            files       = concatUnique (map (s: s.system.files) sets);
          };
          user = {
            directories = concatUnique (map (s: s.user.directories) sets);
            files       = concatUnique (map (s: s.user.files) sets);
          };
        };
    in
    {
      nixosModules = {
        default =
          { config, lib, pkgs, ... }:
          {
            imports = [
              impermanence.nixosModules.impermanence
              ./bcachefs-impermanence.nix
            ];

            # Upstream impermanence's `parentsOf` (lib.nix) computes
            # `take ((length split) - 1) split` to enumerate the parent
            # directories of a persisted path. For a file persisted at the
            # filesystem root (e.g. `/machine-key.json`, whose parent is
            # `/`), `splitPath [ "/" ]` yields `[]`, so `take (-1) []` is
            # evaluated. Older nixpkgs made `lib.take`/`genList` clamp a
            # negative size to an empty list; nixpkgs ffb3c9b (and later)
            # made `genList` throw `cannot create list of size -1`, which
            # breaks evaluation of `system.activationScripts
            # .createPersistentStorageDirs` for any host that persists a
            # root-level file and has bumped its nixpkgs lock.
            #
            # Rather than vendor/replace the whole upstream module, restore
            # the historical `take` semantics for non-positive counts via a
            # scoped overlay on `pkgs.lib`. Upstream impermanence obtains
            # `parentsOf` through `pkgs.callPackage ./lib.nix { }`, so it
            # picks up this guarded `take` automatically. The guard only
            # changes behaviour for counts that would otherwise throw; a
            # zero or negative `take` returning `[]` is what older nixpkgs
            # already did and is the correct "no parents" result for a
            # root-level path.
            nixpkgs.overlays = [
              (_final: prev: {
                lib = prev.lib.extend (_self: super: {
                  take = count: list:
                    if count <= 0 then [ ] else super.take count list;
                });
              })
            ];
          };
      };

      # Library of pre-curated persistence sets. See
      # `./shared_persistence/README.md` for the contract and how to
      # add a new set.
      inherit sharedPersistence;

      # Helpers exposed for host impermanence.nix files.
      lib = {
        inherit mergeSharedPersistence;
      };

      # Standalone disko config for partitioning at install time.
      # Usage from a NixOS live ISO:
      #   sudo nix --experimental-features "nix-command flakes" run \
      #     github:nix-community/disko/latest -- \
      #     --mode destroy,format,mount ./disko-bcachefs.nix \
      #     --arg disk '"/dev/nvme0n1"' \
      #     --arg swapSize '"16G"' \
      #     --arg encrypted true
      #
      # Or reference from a flake:
      #   sudo nix run github:nix-community/disko/latest -- \
      #     --mode destroy,format,mount \
      #     --flake "path:../../flakes/impermanence#bcachefs-impermanence" \
      #     --arg disk '"/dev/nvme0n1"' --arg swapSize '"16G"' --arg encrypted true
      diskoConfigurations.bcachefs-impermanence = import ./disko-bcachefs.nix;
    };
}
