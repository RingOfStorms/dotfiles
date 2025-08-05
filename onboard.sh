#!/bin/sh
# curl -O --proto '=https' --tlsv1.2 -sSf https://git.joshuabell.xyz/ringofstorms/dotfiles/raw/branch/master/onboard.sh

# Go to nix configuration
cd /mnt/etc/nixos

# Ask for required variables
VAR_HOST=$HOSTNAME
VAR_USER=$USERNAME
echo "Hostname will be: $VAR_HOST"
echo "Username will be: $VAR_USER"
while true; do
  read -p "Do you wish to continue? (y/n)" yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please answer y/n.";;
    esac
done

# Switch to use labels in hardware-configuration
# ex +'/fileSystems."\/"' +"/by-uuid" +'s#by-uuid/.*"#by-label/NIXROOT"' \
#     +'/fileSystems."\/boot"' +"/by-uuid" +'s#by-uuid/.*"#by-label/NIXBOOT"' \
#     +"wq" hardware-configuration.nix
# echo "Switched hardware configuration to use labels"
# grep "by-uuid" hardware-configuration.nix # Should show nothing, this will help prompt for changes
# grep "by-label" hardware-configuration.nix
# echo

# echo "TODO add swap section here that asks for sizes..."
# echo

# Download settings needed for initial boot
curl -O https://git.joshuabell.xyz/ringofstorms/dotfiles/raw/branch/master/onboard.nix
# update username and hostname in onboard file
ex +"%s/%%HOSTNAME%%/$VAR_HOST/g" +"%s/%%USERNAME%%/$VAR_USER/g" +"wq" onboard.nix
# Import onboard file in configuration.nix
ex +"%s#hardware-configuration.nix#hardware-configuration.nix ./onboard.nix#g" +"wq" configuration.nix
echo "Setup onboard.nix in configuration.nix"
echo

echo "Run \`nixos-install\` to finish then reboot"
echo "It's recommended to verify contents of hardware config first."
echo
