# Linode setup

https://www.linode.com/docs/guides/install-nixos-on-linode/#prepare-your-linode
https://nixos.org/download/

`export HOSTNAME=NAME && sudo nixos-rebuild switch --flake ~/.config/nixos-config`

# My config

```sh
rsync -e "ssh -i /run/agenix/nix2l002" -Pahz \
  --delete-after \
  --exclude 'flake.lock' \
  ~/.config/nixos-config/hosts/l003/ \
  luser@172.234.26.141:~/.config/nixos-config/
```

