# Steps

Mostly followed: <https://blog.korfuri.fr/posts/2022/08/nixos-on-an-oracle-free-tier-ampere-machine/>

- kexectools -> kexec-tools
- create mnt/boot after mounting mnt
- copy over oracle.nix and import for first nixos-install

# TODO

- check out <https://github.com/elitak/nixos-infect>

- Nixos infect worked well, ran it. It maintains the ssh pub key for root user
- Allow connections in oracle security
    - > Networking > Virtual Cloud Networks > __ network __ > __ subnet __ > __ security list __
    - Add TCP all for ports 80/443 just like 22 has
- copy config/hardware config and deploy
- 
