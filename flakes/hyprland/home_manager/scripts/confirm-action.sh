#!/usr/bin/env bash

COMMAND_TO_RUN="$1"
PROMPT_MESSAGE="$2"

if [ -z "$PROMPT_MESSAGE" ]; then
    PROMPT_MESSAGE="Are you sure?"
fi

choice=$(echo -e "No\nYes" | wofi --dmenu --location center -p "$PROMPT_MESSAGE")

if [ "$choice" == "Yes" ]; then
    eval "$COMMAND_TO_RUN"
fi
