#!/usr/bin/env bash

# Get a list of available Wi-Fi networks
nets=$(nmcli --terse --fields SSID,SECURITY,BARS device wifi list | sed '/^--/d' | sed 's/\\:/__/g')

# Get the current connection status
connected_ssid=$(nmcli -t -f active,ssid dev wifi | egrep '^yes' | cut -d: -f2)

if [[ ! -z "$connected_ssid" ]]; then
    toggle="󰖪 Toggle Wi-Fi Off"
else
    toggle="󰖩 Toggle Wi-Fi On"
fi

# Present the menu to the user
chosen_network=$(echo -e "$toggle\n$nets" | wofi --dmenu --location 3 --yoffset 40 --xoffset -20 -p "Wi-Fi Networks")

# Perform an action based on the user's choice
if [ "$chosen_network" = "$toggle" ]; then
    nmcli radio wifi $([ "$connected_ssid" = "" ] && echo "on" || echo "off")
elif [ ! -z "$chosen_network" ]; then
    ssid=$(echo "$chosen_network" | sed 's/__/\\:/g' | awk -F'  ' '{print $1}')
    nmcli device wifi connect "$ssid"
fi
