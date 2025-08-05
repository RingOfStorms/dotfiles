## To onboard a new machine, you must use a machine that is already onboarded, or the backup authority key saved in a secure location
## Once the new machine is setup at least once, then we can generate/fetch ssh keys from it and add to this list. Then rekey the secrets and commit the changes and pull down from the nix repo

# System key: `cat /etc/ssh/ssh_host_ed25519_key.pub`
#
# from authority
# `nix run github:yaxitech/ragenix -- -i ~/.ssh/ragenix_authority --rules ~/.config/nixos-config/common/secrets/secrets.nix` <-r(eykey)|-e(edit) <File>>

let
  publicKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBdG4tG18VeuEr/g4GM7HWUzHuUVcR9k6oS3TPBs4JRF ragenix authority key"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFzAQ2Dzl8EvQtYLjEZS5K0bQeNop8QRkwrfxMkBagW2 root@gpdPocket3"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIr/aS0qyn5hCLR6wH1P2GhH3hGOqniewMkIseGZ23HB josh@gpdPocket3"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4PwrrOuZJWRjlc2dKBUKKE4ybqifJeVOn7x9J5IxIS josh@joe"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP+GYfPPKxR/18RdD736G7IQhImX/CYU3A+Gifud3CHg root@joe"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9GW9W3DT9AqTonG5rDta3ziZdYOEEdukh2ErJfHxoP root@h002"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC60tzOVF0mcyfnYK2V/omzikuyE8Ol0K+yAjGxBV7q4 luser@h002"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFGp6oInUcGVnDl5axV1EHflMfZUiHxtqNa4eAuye/av root@lio"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxNhtJNx/y4W54kAGmm2pF80l437z1RLWl/GTVKy0Pd josh@lio"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK7bNX7R9ApoX/cHdXIhQdpA2sHrC9ii6VAulboAIJM2 root@oren"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICauUtSa71+oQAiLxp3GMMbmNXcbr9Mc7eK8b/lqZbbS josh@oren"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGTAz6n35c3r8kSuWJM1JzMVx6jK+0EBwpJA5eTIvy3N root@h001"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICRHer3NrJiklp4oDNRCzDxc9fXpXn5rPAXGFce8ugy2 luser@h001"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHsV5r9sWYgrr9t9p12Epzm6WtxN/XsKSCb46+ODQvVT root@h003"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILQLt2Hc+CN6+e7/sf3Fv0FQlp6+yrIbIJ/J9AdnJCjI luser@h003"
  ];
in
{
  ## To make a new secret:
  # - FIRST add file below that you want to create
  # - cd to the secrets directory here
  # - `ragenix --editor=vi -v -e FILE.age` add file below and in the ragenix.nix file
  #
  # TODO come up with a rotate method/encrypt the device keys better. This isn't very secure feeling to me the way I am doing this now. If anyone gains access to any one of my devices, then my secrets are no longer secret. This is not a good model.

  # Git keys
  "nix2github.age" = {
    inherit publicKeys;
  };
  "nix2bitbucket.age" = {
    inherit publicKeys;
  };
  "nix2gitforgejo.age" = {
    inherit publicKeys;
  };
  "nix2gitjosh.age" = {
    inherit publicKeys;
  };
  # Server keys
  "nix2h001.age" = {
    inherit publicKeys;
  };
  "nix2h002.age" = {
    inherit publicKeys;
  };
  "nix2h003.age" = {
    inherit publicKeys;
  };
  "nix2joe.age" = {
    inherit publicKeys;
  };
  "nix2gpdPocket3.age" = {
    inherit publicKeys;
  };
  "nix2t.age" = {
    inherit publicKeys;
  };
  "nix2l002.age" = {
    inherit publicKeys;
  };
  # ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuo6L6V52AzdQIK6fWW9s0aX1yKUUTXbPd8v8IU9p2o nix2linode
  "nix2linode.age" = {
    inherit publicKeys;
  };
  # ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG90Gg6dV3yhZ5+X40vICbeBwV9rfD39/8l9QSqluTw8 nix2oracle
  "nix2oracle.age" = {
    inherit publicKeys;
  };
  "nix2lio.age" = {
    inherit publicKeys;
  };
  "nix2oren.age" = {
    inherit publicKeys;
  };
  # Others
  "github_read_token.age" = {
    inherit publicKeys;
  };
  "headscale_auth.age" = {
    inherit publicKeys;
  };
  "obsidian_sync_env.age" = {
    inherit publicKeys;
  };
  "us_chi_wg.age" = {
    inherit publicKeys;
  };
}
