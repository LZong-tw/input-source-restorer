#!/bin/bash
set -euo pipefail

LABEL="com.example.input-source-restorer"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_PATH="$HOME/.local/bin/input-source-restorer"

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo "Removed $PLIST_PATH"
fi

if [ -f "$BIN_PATH" ]; then
    rm "$BIN_PATH"
    echo "Removed $BIN_PATH"
fi

echo "Done. Log files in ~/.local/log/ preserved."
