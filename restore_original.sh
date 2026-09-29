#!/bin/zsh
set -e
if [[ ! -d /Applications/BuhoLaunchpad.app ]]; then
  echo "BuhoLaunchpad is not installed. OpenLaunchpad was left running."
  exit 1
fi
launchctl bootout "gui/$(id -u)/local.ayang.OpenLaunchpad.autostart" 2>/dev/null || true
pkill -x OpenLaunchpad 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.ayang.OpenLaunchpad.autostart.plist"
open /Applications/BuhoLaunchpad.app
echo "BuhoLaunchpad is active again; OpenLaunchpad source and layout remain available."
