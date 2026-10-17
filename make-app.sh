#!/bin/zsh
# wtmd.app 构建脚本：release 编译 → 组装 .app bundle → 拷贝 SPM 资源包 → 本地签名
# 用法：./make-app.sh [输出目录，默认 ./dist]
# 版本号：优先取环境变量 WTMD_VERSION，否则取最近一个 git tag（去掉前缀 v）

set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="${1:-dist}"
APP_NAME="wtmd"
BUNDLE_ID="cn.wtmd.app"
VERSION="${WTMD_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.2.0}"

echo "── 1/5 release 编译…"
# --disable-sandbox：SwiftPM 自带的构建沙箱在部分受限环境（CI / 受管沙箱）无法启用
swift build -c release --disable-sandbox --product wtmd
BIN=".build/release/$APP_NAME"

echo "── 2/5 组装 $APP_NAME.app…"
APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "── 3/5 拷贝 SPM 资源包（highlight.js / mermaid / katex，缺失会导致预览无高亮无图表无公式）…"
RES_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$RES_BUNDLE" ]]; then
    echo "   ✗ 未找到资源包：$RES_BUNDLE"
    exit 1
fi
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

ICON="Assets/AppIcon.icns"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>      <string>cn.wtmd.workspace-row</string>
            <key>UTTypeDescription</key>     <string>wtmd workspace row</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -f "$ICON" ]]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

echo "── 4/5 签名…"
# 优先级：WTMD_SIGN_IDENTITY 显式指定（make-dmg.sh 传 "-" 强制 ad-hoc，用于
# 对外分发）> 机器上第一枚可用证书（本机自用）> ad-hoc 兜底。
IDENTITY="${WTMD_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning | grep -oE '"[^"]+"' | head -1 | tr -d '"') || true
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
    codesign --force --options runtime --entitlements - --sign "$IDENTITY" "$APP" <<< '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><false/></dict></plist>' >/dev/null 2>&1 \
        || codesign --force --sign "$IDENTITY" "$APP"
    echo "   已用 $IDENTITY 签名"
else
    codesign --force --sign - "$APP"
    echo "   ad-hoc 签名"
fi

echo "── 5/5 校验…"
codesign --verify --verbose "$APP" 2>&1 | tail -1
[[ -f "$APP/Contents/Resources/$(basename "$RES_BUNDLE")/Contents/Resources/Resources/highlight.min.js" ]] \
    || { echo "   ✗ 资源包内容不完整"; exit 1; }
for f in mermaid.min.js katex.min.js katex-embedded.min.css; do
    [[ -f "$APP/Contents/Resources/$(basename "$RES_BUNDLE")/Contents/Resources/Resources/$f" ]] \
        || { echo "   ✗ 资源包缺少 $f"; exit 1; }
done
spctl --assess --type execute "$APP" 2>&1 || true

echo ""
echo "✓ 完成：$APP（版本 $VERSION）"
