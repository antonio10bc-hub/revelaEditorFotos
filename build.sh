#!/bin/zsh
# Compila Revela.swift y lo empaqueta como Revela.app
set -e
cd "$(dirname "$0")"

APP=Revela.app
mkdir -p build
swiftc -parse-as-library -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  Revela.swift -o build/Revela

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Revela "$APP/Contents/MacOS/Revela"
[[ -f AppIcon.icns ]] || swift make_icon.swift
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Idiomas: español (base, las claves) e inglés
for lang in es en; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cp "Localization/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Revela</string>
  <key>CFBundleDisplayName</key><string>Revela</string>
  <key>CFBundleIdentifier</key><string>local.revela.app</string>
  <key>CFBundleExecutable</key><string>Revela</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Listo: $(pwd)/$APP  →  open $APP"
