#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=KeyMeter.app
KC="$PWD/signing/keymeter.keychain-db"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp Info.plist $APP/Contents/
mkdir -p $APP/Contents/Resources
cp -R en.lproj ru.lproj $APP/Contents/Resources/
cp AppIcon.icns $APP/Contents/Resources/
# универсальная сборка: Apple Silicon и Intel
TMP=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macos13.0 main.swift -o $TMP/KeyMeter-arm64 &
ARM=$!
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 main.swift -o $TMP/KeyMeter-x86_64 &
INTEL=$!
wait $ARM
wait $INTEL
lipo -create $TMP/KeyMeter-arm64 $TMP/KeyMeter-x86_64 -o $APP/Contents/MacOS/KeyMeter
rm -rf $TMP

# постоянная подпись, чтобы доступ к мониторингу ввода не слетал после пересборки
security list-keychains -d user -s "$LOGIN" "$KC"
trap 'security list-keychains -d user -s "$LOGIN"' EXIT
security unlock-keychain -p keymeter "$KC"
codesign --force -s "KeyMeter Signing" $APP
echo "готово: $(pwd)/$APP"
