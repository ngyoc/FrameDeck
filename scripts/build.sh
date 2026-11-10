#!/bin/bash
# FrameDeck をリリースビルドして dist/FrameDeck.app を作る。
# Apple Developer Program に未加入のため ad-hoc 署名のみ（公証はしない）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/FrameDeck/FrameDeck.xcodeproj"
DIST="$ROOT/dist"
DERIVED="$ROOT/.build/DerivedData"

echo "==> クリーンビルド（arm64 + x86_64）"
rm -rf "$DIST/FrameDeck.app"
mkdir -p "$DIST"

xcodebuild \
  -project "$PROJECT" \
  -scheme FrameDeck \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  clean build | grep -E "error:|warning:|BUILD" | grep -v AppIntents || true

APP="$DERIVED/Build/Products/Release/FrameDeck.app"
if [ ! -d "$APP" ]; then
  echo "!! ビルド成果物が見つかりません: $APP" >&2
  exit 1
fi

cp -R "$APP" "$DIST/FrameDeck.app"

echo
echo "==> 確認"
VERSION=$(defaults read "$DIST/FrameDeck.app/Contents/Info.plist" CFBundleShortVersionString)
echo "バージョン    : $VERSION"
echo "アーキテクチャ: $(lipo -info "$DIST/FrameDeck.app/Contents/MacOS/FrameDeck" | sed 's/.*are: //')"
echo "サイズ        : $(du -sh "$DIST/FrameDeck.app" | cut -f1)"
codesign --verify --deep --strict "$DIST/FrameDeck.app" && echo "署名        : OK（ad-hoc）"
echo
echo "出力: $DIST/FrameDeck.app"
