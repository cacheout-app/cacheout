#!/bin/bash
# install-watchdog.sh — Install or update the Cacheout watchdog daemon
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHEOUT_DIR="$HOME/.cacheout"
INSTALL_DIR="$CACHEOUT_DIR/watchdog"
PLIST_NAME="com.cacheout.watchdog"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "=== Cacheout Watchdog Installer ==="
echo ""

# Create directories
mkdir -p "$INSTALL_DIR" "$CACHEOUT_DIR"

# Copy watchdog script
cp "$SCRIPT_DIR/cacheout-watchdog.sh" "$INSTALL_DIR/cacheout-watchdog.sh"
chmod +x "$INSTALL_DIR/cacheout-watchdog.sh"
echo "Installed watchdog script to: $INSTALL_DIR/cacheout-watchdog.sh"

# Generate plist with correct paths
sed \
    -e "s|WATCHDOG_PATH_PLACEHOLDER|$INSTALL_DIR/cacheout-watchdog.sh|g" \
    -e "s|CACHEOUT_DIR_PLACEHOLDER|$CACHEOUT_DIR|g" \
    "$SCRIPT_DIR/com.cacheout.watchdog.plist" > "$PLIST_DEST"
echo "Installed launchd plist to: $PLIST_DEST"

# Unload if already running, then load
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
echo ""
echo "Watchdog is now running (every 30 seconds)."
echo ""
echo "  Logs:    $CACHEOUT_DIR/watchdog.log"
echo "  Alerts:  $CACHEOUT_DIR/alert.json"
echo "  History: $CACHEOUT_DIR/watchdog-history.json"
echo ""
echo "To stop:   launchctl bootout gui/$(id -u)/$PLIST_NAME"
echo "To check:  cat $CACHEOUT_DIR/watchdog.log | tail -20"
