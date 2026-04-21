#!/bin/bash
set -euo pipefail

# Install input-source-restorer as a user LaunchAgent on macOS.
# Requires: Xcode Command Line Tools (for swiftc).

BIN_DIR="$HOME/.local/bin"
LOG_DIR="$HOME/.local/log"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.example.input-source-restorer"
BIN_PATH="$BIN_DIR/input-source-restorer"
PLIST_PATH="$AGENT_DIR/$LABEL.plist"

cd "$(dirname "$0")"

echo "==> Compiling input-source-restorer.swift"
mkdir -p "$BIN_DIR"
swiftc input-source-restorer.swift -o "$BIN_PATH" -framework Carbon

echo "==> Creating log directory"
mkdir -p "$LOG_DIR"

echo "==> Installing LaunchAgent"
mkdir -p "$AGENT_DIR"
sed -e "s|__INSTALL_PATH__|$BIN_PATH|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    com.example.input-source-restorer.plist > "$PLIST_PATH"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "==> Installed. Verifying..."
sleep 1
if launchctl list | grep -q "$LABEL"; then
    echo "OK: $LABEL is running"
    echo "    Binary:  $BIN_PATH"
    echo "    Log:     $LOG_DIR/input-source-restorer.log"
else
    echo "WARN: agent not listed. Check $LOG_DIR/input-source-restorer.err"
    exit 1
fi
