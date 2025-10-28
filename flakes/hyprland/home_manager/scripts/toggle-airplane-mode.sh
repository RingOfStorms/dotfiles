#!/usr/bin/env bash
if [ "$(nmcli radio all)" = "enabled" ]; then
  nmcli radio all off
else
  nmcli radio all on
fi
