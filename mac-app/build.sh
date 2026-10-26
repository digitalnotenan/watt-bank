#!/bin/bash
# Builds "Watt Bank.app" from WattBank.swift with the Command Line Tools (no Xcode needed).
set -e
cd "$(dirname "$0")"
export TMPDIR=$(getconf DARWIN_USER_TEMP_DIR)
APP="build/Watt Bank.app"
rm -rf build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 WattBank.swift -o "$APP/Contents/MacOS/WattBank"

# Save helper (PKHeX.Core): reads/moves money in game saves of every generation
if [ ! -f wbsave/out/wbsave ] && command -v dotnet >/dev/null; then
  echo "Building the save helper (wbsave)…"
  (cd wbsave && dotnet publish -c Release -r osx-arm64 --self-contained true -p:PublishSingleFile=true \
      -p:IncludeNativeLibrariesForSelfExtract=true -o out >/dev/null) || echo "wbsave build failed: save features stay off"
fi
if [ -f wbsave/out/wbsave ]; then cp wbsave/out/wbsave "$APP/Contents/Resources/wbsave"; codesign --force -s - "$APP/Contents/Resources/wbsave"; fi
# IR head firmware and the iPhone Shortcut, offered from inside the app (repo layout first, then local copies)
for f in ../firmware/wattbank_ir/wattbank_ir.ino "../ESP32 firmware/wattbank_ir/wattbank_ir.ino" wattbank_ir.ino; do
  [ -f "$f" ] && { cp "$f" "$APP/Contents/Resources/wattbank_ir.ino"; break; }; done
for f in "../shortcuts/Watt Bank Health Sync.shortcut" "Watt Bank Health Sync.shortcut"; do
  [ -f "$f" ] && { cp "$f" "$APP/Contents/Resources/Watt Bank Health Sync.shortcut"; break; }; done
# One-click firmware install: prebuilt IR head firmware + esptool (repo layout first, then local copies)
FW="$APP/Contents/Resources/firmware"; mkdir -p "$FW"
for d in ../firmware/build firmware; do
  [ -f "$d/wattbank_ir.bin" ] && { cp "$d"/wattbank_ir.bin "$d"/wattbank_ir.bootloader.bin "$d"/wattbank_ir.partitions.bin "$d"/boot_app0.bin "$FW/"; break; }; done
ESPTOOL=""
for e in firmware/esptool ../firmware/tools/esptool "$HOME"/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool "$(command -v esptool 2>/dev/null)"; do
  [ -n "$e" ] && [ -x "$e" ] && { ESPTOOL="$e"; break; }; done
if [ -n "$ESPTOOL" ]; then cp "$ESPTOOL" "$FW/esptool"; else echo "note: esptool not found, the app will offer only the Arduino IDE route"; fi
# Calories card flames (wallpaper masks)
for f in fire_flames.png fire_mid.png fire_core.png; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/$f"; done
# Guide pictures (IR head + iPhone Shortcut)
[ -d guide ] && { mkdir -p "$APP/Contents/Resources/guide"; cp guide/*.png "$APP/Contents/Resources/guide/"; }
# Locked-in card art (card_watt.png, card_debit.png, …) lives in the app itself
for f in card_*.png card_*.pdf; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/$f"; done

# App icon + in-app logo: drawn by make_icon.swift (original artwork)
swiftc -swift-version 5 make_icon.swift -o build/make_icon
build/make_icon build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d build/icon_1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
sips -z 256 256 build/icon_1024.png --out "$APP/Contents/Resources/logo.png" >/dev/null

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Watt Bank</string>
  <key>CFBundleDisplayName</key><string>Watt Bank</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-io.github.digitalnotenan.wattbank}</string>
  <key>CFBundleExecutable</key><string>WattBank</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>9.4</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"
echo "BUILD OK: $APP"
