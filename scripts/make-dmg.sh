#!/bin/bash
# dist/FrameDeck.app から配布用の dmg を作る。
# 先に scripts/build.sh を実行しておくこと。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/FrameDeck.app"

if [ ! -d "$APP" ]; then
  echo "!! $APP がありません。先に scripts/build.sh を実行してください。" >&2
  exit 1
fi

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
DMG="$DIST/FrameDeck-$VERSION.dmg"
STAGE="$DIST/.stage"

echo "==> 中身を組み立て"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/FrameDeck.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/INSTALL.md" "$STAGE/はじめにお読みください.txt"

echo "==> dmg を作成"
hdiutil create \
  -volname "FrameDeck $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

rm -rf "$STAGE"

echo
echo "==> 確認"
hdiutil verify "$DMG" >/dev/null && echo "検証: OK"
echo "サイズ: $(du -sh "$DMG" | cut -f1)"
echo
echo "出力: $DMG"
echo
echo "渡す相手には dmg と一緒に、中の「はじめにお読みください.txt」の手順を伝えてください。"
