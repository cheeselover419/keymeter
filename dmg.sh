#!/bin/zsh
# образ диска для раздачи: KeyMeter.app и ярлык «Программы»
set -e
cd "$(dirname "$0")"
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="KeyMeter-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ditto KeyMeter.app "$STAGE/KeyMeter.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname KeyMeter -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
echo "готово: $(pwd)/$DMG"
