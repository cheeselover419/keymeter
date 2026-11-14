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
swiftc -O -parse-as-library main.swift -o $APP/Contents/MacOS/KeyMeter

# постоянная подпись, чтобы доступ к мониторингу ввода не слетал после пересборки
security list-keychains -d user -s "$LOGIN" "$KC"
trap 'security list-keychains -d user -s "$LOGIN"' EXIT
security unlock-keychain -p keymeter "$KC"
codesign --force -s "KeyMeter Signing" $APP
echo "готово: $(pwd)/$APP"
