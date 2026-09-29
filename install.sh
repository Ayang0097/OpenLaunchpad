#!/bin/zsh
set -e
cd "${0:A:h}"
./build.sh
agent="$HOME/Library/LaunchAgents/local.ayang.OpenLaunchpad.autostart.plist"
launchctl bootout "gui/$(id -u)/local.ayang.OpenLaunchpad.autostart" 2>/dev/null || true
pkill -x OpenLaunchpad 2>/dev/null || true
ditto dist/OpenLaunchpad.app /Applications/OpenLaunchpad.app
mkdir -p "$HOME/Library/LaunchAgents"
cp LaunchAgent.plist "$agent"
launchctl bootstrap "gui/$(id -u)" "$agent"
codesign --verify --deep --strict /Applications/OpenLaunchpad.app
touch /Applications/OpenLaunchpad.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/OpenLaunchpad.app
echo "Installed: /Applications/OpenLaunchpad.app"
