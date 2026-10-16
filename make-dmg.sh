#!/bin/zsh
# 打包 DMG：wtmd.app + /Applications 快捷方式
# 用法：./make-dmg.sh
# 说明：v0.2 只搭链路，首个对外 DMG 计划在 v0.3 首发。

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${WTMD_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.2.0}"
DMG="dist/wtmd-$VERSION.dmg"
STAGING="dist/dmg-staging"

./make-app.sh dist >/dev/null

echo "── 组装 DMG…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R dist/wtmd.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "wtmd" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGING"

echo "── 签名 DMG…"
IDENTITY=$(security find-identity -v -p codesigning | grep -oE '"[^"]+"' | head -1 | tr -d '"') || true
if [[ -n "${IDENTITY:-}" ]]; then
    codesign --sign "$IDENTITY" "$DMG"
else
    codesign --sign - "$DMG"
fi

echo ""
echo "✓ 完成：$DMG"
echo ""
echo "⚠ 分发提示：当前为 Apple Development 签名，仅限本机/开发者设备运行。"
echo "  对外分发需要 Developer ID Application 证书 + 公证："
echo "    xcrun notarytool submit $DMG --apple-id <id> --team-id <team> --wait"
echo "    xcrun stapler staple $DMG"
