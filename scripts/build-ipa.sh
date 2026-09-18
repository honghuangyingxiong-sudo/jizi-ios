#!/usr/bin/env bash
# 在 Mac 上本地出无签名 IPA（Windows 上跑不了，用 GitHub Actions）。
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

xcodebuild \
  -project JiZi.xcodeproj \
  -scheme JiZi \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP="build/Build/Products/Release-iphoneos/JiZi.app"
rm -rf Payload JiZi.ipa
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry JiZi.ipa Payload
echo "OK -> $(pwd)/JiZi.ipa"
shasum -a 256 JiZi.ipa
