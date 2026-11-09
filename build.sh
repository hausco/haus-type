#!/usr/bin/env bash
# 編譯 HAUS Type.app。
# 用法：./build.sh            編譯＋安裝到 /Applications＋重開（自用開發）
#       ./build.sh --no-open  編譯＋安裝，不重開
#       ./build.sh --release  發佈用：Developer ID 簽章＋時間戳記，只輸出到 build/，不安裝（release.sh 會呼叫）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HAUS Type"
EXEC="HAUSType"
BUNDLE_ID="tw.haus.type"
OUT="build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"
VERSION="$(cat VERSION)"
MODE="${1:-}"

# 1. 編譯成 .app 結構
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
# Universal：Apple Silicon 與 Intel 各編一次再合併
TMPBIN="$(mktemp -d)"
swiftc -O -target arm64-apple-macos14 -o "$TMPBIN/arm64" Sources/*.swift
swiftc -O -target x86_64-apple-macos14 -o "$TMPBIN/x86_64" Sources/*.swift
lipo -create "$TMPBIN/arm64" "$TMPBIN/x86_64" -output "$OUT/Contents/MacOS/$EXEC"

cp icon/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

# 2. Info.plist：LSUIElement＝只在選單列，不出現在 Dock
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${EXEC}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>$(date +%y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>HAUS Type 要用麥克風聽你講話，轉成文字寫進輸入框。</string>
</dict></plist>
PLIST

# 3. 簽名：用 Apple Development 憑證（以 SHA-1 指定，避免同名憑證不明確）。
#    同一張憑證＋同一個 bundle id，重編後麥克風與輔助使用權限不用重給。
# 優先用 Developer ID（發佈與自用同一張憑證，權限才不會因換簽章而失效），沒有才退回 Apple Development
IDS="$(security find-identity -v -p codesigning)"
IDENTITY="${HAUSTYPE_SIGN_IDENTITY:-$(grep -m1 '"Developer ID Application: ' <<<"$IDS" | awk '{print $2}')}"
[[ -n "$IDENTITY" || "$MODE" == "--release" ]] || IDENTITY="$(grep -m1 '"Apple Development: ' <<<"$IDS" | awk '{print $2}')"
if [[ "$MODE" == "--release" && -z "$IDENTITY" ]]; then echo "發佈需要 Developer ID Application 憑證" >&2; exit 1; fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --entitlements entitlements.plist --sign "$IDENTITY" "$OUT"
else
  echo "找不到 Apple Development 憑證，改用本機簽名（每次重編權限要重給）" >&2
  codesign --force --entitlements entitlements.plist --sign - "$OUT"
fi

# 發佈模式到這裡結束，不安裝
if [[ "$MODE" == "--release" ]]; then echo "已輸出：$OUT（$VERSION）"; exit 0; fi

# 4. 安裝並重開
if [[ "$MODE" != "--no-open" ]]; then
  pkill -x "$EXEC" 2>/dev/null && sleep 1 || true
  pkill -x YuVoice 2>/dev/null || true
fi
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$OUT" "$DEST"
echo "已安裝：$DEST"
if [[ "$MODE" != "--no-open" ]]; then
  open "$DEST"
fi
