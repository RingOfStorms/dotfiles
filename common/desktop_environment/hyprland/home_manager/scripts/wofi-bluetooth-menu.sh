#!/usr/bin/env bash

devices=$(bluetoothctl devices | awk '{print $2, $3}')

if [ -z "$devices" ]; then
    options="󰂲 Power On\n󰂬 Scan for devices"
else
    options="$devices\n󰂲 Power Off\n󰂬 Scan for devices"
fi

chosen=$(echo -e "$options" | wofi --dmenu --location 3 --yoffset 40 --xoffset -20 -p "Bluetooth")

case "$chosen" in
    "󰂲 Power On") bluetoothctl power on;;
    "󰂲 Power Off") bluetoothctl power off;;
    "󰂬 Scan for devices") bluetoothctl scan on;;
    *) 
        mac=$(echo "$chosen" | awk '{print $1}')
        bluetoothctl connect "$mac"
        ;;
esac
