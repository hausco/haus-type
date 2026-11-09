#!/usr/bin/env bash
# 一鍵發佈：編譯 → Developer ID 簽章 → 公證 app → 做 DMG → 簽章並公證 DMG → 驗證。
# 用法：./release.sh            版本號讀 VERSION 檔
# 需要：Developer ID Application 憑證、notarytool 憑證設定檔（預設名稱 yuvoice-notary）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
PROFILE="${NOTARY_PROFILE:-yuvoice-notary}"  # 公證設定檔沿用改名前存的名稱
APP="build/HAUS Type.app"
DIST="dist"
DMG="$DIST/HAUS-Type-$VERSION.dmg"
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application: ' | awk '{print $2}')"
[[ -n "$IDENTITY" ]] || { echo "找不到 Developer ID Application 憑證" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "找不到公證憑證設定檔 $PROFILE，先跑 xcrun notarytool store-credentials $PROFILE" >&2; exit 1; }

# 1. 編譯並簽章
./build.sh --release
mkdir -p "$DIST"

# 2. 公證 app（壓成 zip 上傳，等 Apple 回覆），通過後把公證票釘進 app
echo "公證 app 中（通常 1 到 5 分鐘）…"
ditto -c -k --keepParent "$APP" "$DIST/HAUS-Type-$VERSION-app.zip"
xcrun notarytool submit "$DIST/HAUS-Type-$VERSION-app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$DIST/HAUS-Type-$VERSION-app.zip"

# 3. 做 DMG：app＋「應用程式」捷徑，使用者拖過去就裝好
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/HAUS Type.app"
ln -s /Applications "$STAGE/應用程式"
rm -f "$DMG"
hdiutil create -volname "HAUS Type $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

# 4. 公證 DMG 並釘票
echo "公證 DMG 中…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 5. 驗證：Gatekeeper 要回 accepted、source=Notarized Developer ID
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "完成：$DMG"
shasum -a 256 "$DMG"
