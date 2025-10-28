#!/usr/bin/env bash
if [ "$(powerprofilesctl get)" = "performance" ]; then
  powerprofilesctl set balanced
else
  powerprofilesctl set performance
fi
