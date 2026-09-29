#!/bin/zsh
set -e
cd "${0:A:h}"
mkdir -p dist/OpenLaunchpad.app/Contents/MacOS
mkdir -p dist/OpenLaunchpad.app/Contents/Resources
if [[ ! -f Resources/AppIcon.icns || make_icon.swift -nt Resources/AppIcon.icns ]]; then
  mkdir -p Resources/icon.iconset
  swift -target arm64-apple-macos14.0 make_icon.swift Resources/icon.iconset/icon_512x512@2x.png
  for dimension in 16 32 128 256 512; do
    sips -z $dimension $dimension Resources/icon.iconset/icon_512x512@2x.png --out Resources/icon.iconset/icon_${dimension}x${dimension}.png >/dev/null
    doubled=$((dimension * 2))
    sips -z $doubled $doubled Resources/icon.iconset/icon_512x512@2x.png --out Resources/icon.iconset/icon_${dimension}x${dimension}@2x.png >/dev/null
  done
  iconutil -c icns Resources/icon.iconset -o Resources/AppIcon.icns
fi
swiftc -target arm64-apple-macos14.0 -O Sources/main.swift -o dist/OpenLaunchpad.app/Contents/MacOS/OpenLaunchpad
cp Info.plist dist/OpenLaunchpad.app/Contents/Info.plist
cp Resources/AppIcon.icns dist/OpenLaunchpad.app/Contents/Resources/AppIcon.icns
icon_hash=$(shasum Resources/AppIcon.icns | cut -c 1-12)
icon_name="AppIcon-$icon_hash"
cp Resources/AppIcon.icns "dist/OpenLaunchpad.app/Contents/Resources/$icon_name.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $icon_name" dist/OpenLaunchpad.app/Contents/Info.plist
codesign --force --deep --sign - dist/OpenLaunchpad.app
echo "Built: $PWD/dist/OpenLaunchpad.app"
