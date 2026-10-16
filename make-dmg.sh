#!/bin/zsh
# 打包对外分发的 DMG：wtmd.app + /Applications 快捷方式 + 背景图与窗口布局。
# 用法：./make-dmg.sh
#
# 签名策略（对外分发）：默认 ad-hoc（codesign --sign -）。
# 本仓库没有 Developer ID Application 证书，无法公证；Apple Development 签名
# 对陌生机器同样过不了 Gatekeeper，还会带上 get-task-allow 调试 entitlement，
# 对外分发是更差的产物。需要 Developer ID 签名时：
#   WTMD_SIGN_IDENTITY="Developer ID Application: …" ./make-dmg.sh
#
# 新机器首次打开被 Gatekeeper 拦截属预期行为，引导见 README「安装」一节。

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${WTMD_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.2.0}"
DMG="dist/wtmd-$VERSION.dmg"
STAGING="dist/dmg-staging"
RW_DMG="dist/wtmd-rw.dmg"

# DMG 窗口布局（内容区，单位 pt）。这些常量必须与
# Assets/gen_dmg_background.swift 顶部的 iconSize / appCenterX /
# appsCenterX / iconRowY / W / H 保持一致。
DMG_ICON_SIZE=128
DMG_APP_CENTER_X=170
DMG_APPS_CENTER_X=490
DMG_ICON_ROW_Y=200
DMG_W=660
DMG_H=440
# 标题栏高度：Finder 的 bounds 含标题栏，背景图只铺内容区。
DMG_TITLEBAR_H=28

APP_SIGN_IDENTITY="${WTMD_SIGN_IDENTITY:--}"

echo "── 1/6 生成 DMG 背景图…"
swift Assets/gen_dmg_background.swift Assets >/dev/null
[[ -f Assets/dmg-background.tiff ]] || { echo "   ✗ 背景图未生成"; exit 1; }

echo "── 2/6 构建 wtmd.app…"
WTMD_SIGN_IDENTITY="$APP_SIGN_IDENTITY" ./make-app.sh dist

echo "── 3/6 组装 DMG 内容…"
rm -rf "$STAGING" "$RW_DMG"
mkdir -p "$STAGING/.background"
cp -R dist/wtmd.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp Assets/dmg-background.tiff "$STAGING/.background/"

hdiutil create -volname "wtmd" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -ov -format UDRW \
    "$RW_DMG" >/dev/null

MOUNT_DIR=$(hdiutil attach -readwrite -nobrowse -noautoopen "$RW_DMG" 2>/dev/null \
    | awk -F'\t' '/\/Volumes\//{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
[[ -n "$MOUNT_DIR" ]] || { echo "   ✗ 挂载失败"; exit 1; }

echo "── 4/6 设置 DMG 窗口布局…"
# Finder 把背景图画在窗口内容区，坐标以内容区左上角为原点；position 是图标
# 左上角，因此居中位置要减去半个图标。布局失败（如无 GUI / 自动化权限被拒）
# 只影响观感，不应让发布中断。
LAYOUT_ERR=$(mktemp)
if osascript -e "
tell application \"Finder\"
    tell disk \"wtmd\"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, $((200 + DMG_W)), $((200 + DMG_H + DMG_TITLEBAR_H))}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $DMG_ICON_SIZE
        set background picture of theViewOptions to file \".background:dmg-background.tiff\"
        set position of item \"wtmd.app\" of container window to {$((DMG_APP_CENTER_X - DMG_ICON_SIZE / 2)), $((DMG_ICON_ROW_Y - DMG_ICON_SIZE / 2))}
        set position of item \"Applications\" of container window to {$((DMG_APPS_CENTER_X - DMG_ICON_SIZE / 2)), $((DMG_ICON_ROW_Y - DMG_ICON_SIZE / 2))}
        update without registering applications
        delay 1
        close
    end tell
end tell" 2>"$LAYOUT_ERR"; then
    echo "   布局已写入（窗口 ${DMG_W}x$((DMG_H + DMG_TITLEBAR_H))，图标 $DMG_ICON_SIZE）"
else
    echo "   ⚠ 无法配置 Finder 布局（$(head -1 "$LAYOUT_ERR")），DMG 将使用默认视图。"
    echo "     布局只是观感问题，产物可用；需要布局时在自己的终端重跑本脚本——"
    echo "     首次会弹出「<终端> 想要控制 Finder」的授权框，点允许即可。"
fi
rm -f "$LAYOUT_ERR"

sync
sleep 1
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null

echo "── 5/6 压缩为最终 DMG…"
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"

echo "── 6/6 签名与校验…"
codesign --sign "$APP_SIGN_IDENTITY" "$DMG"
hdiutil verify "$DMG" >/dev/null && echo "   hdiutil verify 通过"

echo ""
echo "✓ 完成：$DMG"
echo ""
echo "⚠ 分发提示：本仓库无 Developer ID 证书，产物为 ad-hoc 签名、未公证。"
echo "  新机器首次打开会被 Gatekeeper 拦截（macOS 15+ 已无法用「右键 → 打开」绕过）："
echo "    · 系统设置 › 隐私与安全性 › 仍要打开"
echo "    · 或：xattr -cr /Applications/wtmd.app"
echo "  完整引导见 README「安装」一节。"
