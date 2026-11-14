#!/bin/zsh
# образ диска для раздачи: KeyMeter.app, ярлык «Программы» и фон со стрелкой
set -e
cd "$(dirname "$0")"
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="KeyMeter-$VERSION.dmg"
VOL="KeyMeter"
TMP=$(mktemp -d)
MNT="/Volumes/$VOL"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null; rm -rf "$TMP"' EXIT

# если образ с таким именем уже подключён, Finder не найдёт нужное окно
hdiutil detach "$MNT" -quiet 2>/dev/null || true

# сначала перезаписываемый образ, чтобы Finder сохранил в нём вид окна
hdiutil create -volname "$VOL" -size 20m -fs HFS+ -ov "$TMP/rw.dmg" > /dev/null
hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "$MNT" > /dev/null
ditto KeyMeter.app "$MNT/KeyMeter.app"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background"
cp dmg/background.tiff "$MNT/.background/background.tiff"

# окно 600×380, значки 128, приложение слева, «Программы» справа
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 500}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "KeyMeter.app" of container window to {160, 180}
        set position of item "Applications" of container window to {440, 180}
        update without registering applications
        delay 1
        -- Finder иногда сбрасывает размер, пока окно открывается
        set bounds of container window to {200, 120, 800, 500}
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MNT" -quiet
rm -f "$DMG"
hdiutil convert "$TMP/rw.dmg" -format UDZO -o "$DMG" > /dev/null
echo "готово: $(pwd)/$DMG"
