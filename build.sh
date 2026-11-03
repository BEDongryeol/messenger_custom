#!/bin/bash
# 배포 패키지 빌드
#   dist/DooraySkin-mac.zip          : Dooray Skin.app + 제거.command + 설치방법.txt  (앱 더블클릭 한 번)
#   dist/DooraySkin-Setup.cmd        : Windows cmd 설치기 (exe 는 Windows 에서 build-windows.ps1 로 빌드)
#   dist/DooraySkin-windows.zip      : 위 cmd + 설치방법.txt (메신저/메일이 .cmd 첨부를 막을 때용)
#   dist/DooraySkin-chrome-extension.zip
set -euo pipefail
cd "$(dirname "$0")"
VER=$(grep -o "VERSION = '[0-9.]*'" src/core.js | grep -o "[0-9.]*")
rm -rf dist && mkdir -p dist
crlf() { sed -e $'s/\r$//' -e $'s/$/\r/' "$1"; }
bom_crlf() { printf '\xEF\xBB\xBF'; crlf "$1"; }

# ---------- mac ----------
M=dist/mac; A="$M/Dooray Skin.app"
mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp installer/mac/app/DooraySkin "$A/Contents/MacOS/DooraySkin"
cp installer/mac/app/dock.sh src/core.js src/launcher.js "$A/Contents/Resources/"
chmod +x "$A/Contents/MacOS/DooraySkin" "$A/Contents/Resources/dock.sh"
cp "/Applications/Dooray Messenger.app/Contents/Resources/electron.icns" "$A/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Dooray Skin</string>
  <key>CFBundleDisplayName</key><string>Dooray Skin</string>
  <key>CFBundleIdentifier</key><string>local.dooray-skin.launcher</string>
  <key>CFBundleExecutable</key><string>DooraySkin</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp "installer/mac/Dooray Skin 제거.command" "installer/mac/설치방법.txt" "$M/"
chmod +x "$M/Dooray Skin 제거.command"
xattr -cr "$M" 2>/dev/null || true
(cd "$M" && ditto -c -k --norsrc --noextattr "." ../DooraySkin-mac.zip)

# ---------- windows: 단일 cmd ----------
P=installer/windows/payload
TMPD=$(mktemp -d)
for f in common.ps1 launch.ps1 uninstall.ps1 setup.ps1 toast-host.ps1; do bom_crlf "$P/$f" > "$TMPD/$f"; done
crlf "$P/launch.vbs" > "$TMPD/launch.vbs"
cp src/core.js "$TMPD/"
S=dist/DooraySkin-Setup.cmd
{
  crlf installer/windows/setup-head.cmd
  printf '#DRB_PS_BEGIN\r\n'
  printf '# Dooray Skin v%s\r\n' "$VER"
  printf '$EmbeddedFiles = @{\r\n'
  for f in core.js common.ps1 launch.ps1 launch.vbs uninstall.ps1 setup.ps1 toast-host.ps1; do
    printf "  '%s' = '%s'\r\n" "$f" "$(base64 -i "$TMPD/$f" | tr -d '\n')"
  done
  printf '}\r\n'
  crlf installer/windows/payload/setup.ps1
} > "$S"
W=dist/windows; mkdir -p "$W"
cp "$S" "$W/"
bom_crlf "installer/windows/설치방법.txt" > "$W/README.txt"
(cd "$W" && zip -qr ../DooraySkin-windows.zip .)
rm -rf "$TMPD"

# ---------- chrome extension ----------
C=dist/chrome; mkdir -p "$C"
cp chrome-extension/manifest.json src/core.js "$C/"; bom_crlf chrome-extension/README.txt > "$C/README.txt"
(cd "$C" && zip -qr ../DooraySkin-chrome-extension.zip .)

echo "built v$VER"
ls -la dist
