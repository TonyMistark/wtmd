#!/bin/zsh
# 打包对外分发的 DMG：wtmd.app + /Applications 快捷方式 + 背景图与窗口布局。
# 用法：./make-dmg.sh
# 可选依赖：窗口布局需要 Python 的 ds_store + mac_alias（pip install dmgbuild）；
# 缺失时布局降级为默认视图，产物照常生成。可用 WTMD_LAYOUT_PY 指定解释器。
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

# 组装过程放临时目录：`dist/` 只留一个 dmg。
# 把 wtmd.app 直接建在 dist/ 下时，Spotlight 会把
# ~/projects/wtmd/dist/wtmd.app 也收进「应用」，于是「Apps」里出现两个 wtmd
# ——一个是 /Applications 里装的，一个是仓库里的构建产物。构建产物不该出现在
# 任何「应用」列表里，所以这里连落脚点都挪到 Spotlight 不看的临时目录。
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/wtmd-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/app/wtmd.app"
IMAGE="$STAGING/image"
RW_DMG="$STAGING/wtmd-rw.dmg"

mkdir -p dist
# 兜底：即使以后有人往 dist/ 里丢了个 .app，这个标记也会让 Spotlight 整棵跳过。
: > dist/.metadata_never_index
# 老版本留下的中间目录（也曾经被索引成「应用」）。
rm -rf dist/dmg-staging dist/wtmd.app

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
WTMD_SIGN_IDENTITY="$APP_SIGN_IDENTITY" ./make-app.sh "$STAGING/app"

echo "── 3/6 组装 DMG 内容…"
mkdir -p "$IMAGE/.background"
cp -R "$APP" "$IMAGE/"
ln -s /Applications "$IMAGE/Applications"
cp Assets/dmg-background.tiff "$IMAGE/.background/"

hdiutil create -volname "wtmd" \
    -srcfolder "$IMAGE" \
    -fs HFS+ \
    -ov -format UDRW \
    "$RW_DMG" >/dev/null

MOUNT_DIR=$(hdiutil attach -readwrite -nobrowse -noautoopen "$RW_DMG" 2>/dev/null \
    | awk -F'\t' '/\/Volumes\//{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
[[ -n "$MOUNT_DIR" ]] || { echo "   ✗ 挂载失败"; exit 1; }

echo "── 4/6 写入 DMG 窗口布局…"
# 布局直接写进卷内的 .DS_Store（bwsp 窗口 bounds / icvp 图标视图选项与背景图
# alias / icvl / 每项 Iloc），配方与 dmgbuild 同源。坐标是图标左上角，与
# Assets/gen_dmg_background.swift 和 Assets/write_dmg_layout.py 顶部常量同步。
# 这一步不依赖 Finder 自动化（osascript 的 Apple Events 需要 TCC 授权，在
# 无头/受限环境拿不到），找不到依赖时降级为默认视图，发布不因此中断。
LAYOUT_PY="${WTMD_LAYOUT_PY:-}"
if [[ -z "$LAYOUT_PY" ]]; then
    for py in python3 python /usr/bin/python3; do
        command -v "$py" >/dev/null 2>&1 || continue
        "$py" -c "import ds_store, mac_alias" >/dev/null 2>&1 && { LAYOUT_PY="$py"; break; }
    done
fi
if [[ -n "$LAYOUT_PY" ]]; then
    "$LAYOUT_PY" Assets/write_dmg_layout.py "$MOUNT_DIR" \
        && echo "   布局已写入（窗口 ${DMG_W}x$((DMG_H + DMG_TITLEBAR_H))，图标 $DMG_ICON_SIZE）" \
        || echo "   ⚠ 布局写入失败，DMG 将使用默认视图（只是观感，产物可用）"
else
    echo "   ⚠ 未找到带 ds_store/mac_alias 的 Python，跳过窗口布局（只是观感，产物可用）。"
    echo "     需要布局时：pip install dmgbuild，或用 WTMD_LAYOUT_PY=<python> 指定解释器。"
fi

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
echo "  dist/ 里只有这一个文件（.app 是临时目录里拼的，装完就没了）。"
echo ""
echo "⚠ 分发提示：本仓库无 Developer ID 证书，产物为 ad-hoc 签名、未公证。"
echo "  新机器首次打开会被 Gatekeeper 拦截（macOS 15+ 已无法用「右键 → 打开」绕过）："
echo "    · 系统设置 › 隐私与安全性 › 仍要打开"
echo "    · 或：xattr -cr /Applications/wtmd.app"
echo "  完整引导见 README「安装」一节。"
