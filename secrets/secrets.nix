## To onboard a new machine, you must use a machine that is already onboarded, or the backup authority key saved in a secure location
## Once the new machine is setup at least once, then we can generate/fetch ssh keys from it and add to this list. Then rekey the secrets and commit the changes and pull down from the nix repo

# System key: `cat /etc/ssh/ssh_host_ed25519_key.pub`
#
# from authority
# `nix run github:yaxitech/ragenix/ -- -i ~/.ssh/ragenix_authority --rules /etc/nixos/secrets/secrets.nix` <-r(eykey)|-e(edit) <File>>

let
  publicKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBdG4tG18VeuEr/g4GM7HWUzHuUVcR9k6oS3TPBs4JRF ragenix authority key"
    # gpdPocket3
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhgYzACsd0GPuF8bl9SFB5y9KDwv+pU9UihoInzhRok josh@gpdPocket3"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJnV4aVyKStFH1KySfnuqBq+DLvyvJhRfKtMs7PCKlIq root@nixos"
    # joe
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4PwrrOuZJWRjlc2dKBUKKE4ybqifJeVOn7x9J5IxIS josh@joe"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP+GYfPPKxR/18RdD736G7IQhImX/CYU3A+Gifud3CHg root@joe"
  ];
in
{
  # TODO come up with a rotate method/encrypt the device keys bette. This isn't very secure feeling to me the way I am doing this now. If anyone gains access to any one of my devices, then my secrets are no longer secret. This is not a good model.
  "nix2github.age" = { inherit publicKeys; };
  "nix2bitbucket.age" = { inherit publicKeys; };
}
