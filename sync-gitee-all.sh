#!/bin/sh
# Sync every published GitHub release to Gitee, oldest first.
#
# Usage: ./sync-gitee-all.sh
#
# Why a batch script: the per-release `sync-gitee-release.sh` only knows one
# tag, and the mirror is allowed to lag. When it lags by a dozen versions the
# update checker's Gitee source answers 404 — which reads to the user as
# "sometimes the update works, sometimes it doesn't". This walks every GitHub
# release, skips the ones Gitee already has, downloads each dmg from GitHub and
# hands it to the single-release script.
#
# Auth: same token file as the single-release script —
#   $GITEE_TOKEN, or ~/.config/wtmd/gitee-token (chmod 600, projects scope).
set -eu
cd "$(dirname "$0")"

OWNER="Micestark"
REPO="Micestark/wtmd"
API="https://gitee.com/api/v5/repos/$REPO"
TOKEN_FILE="$HOME/.config/wtmd/gitee-token"

TOKEN="${GITEE_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
    TOKEN="$(tr -d ' \n' < "$TOKEN_FILE")"
fi
if [ -z "$TOKEN" ]; then
    echo "⚠️  没有 Gitee 令牌，未同步任何版本。"
    echo "   1. gitee.com › 设置 › 私人令牌 › 生成新令牌（勾 projects 权限）"
    echo "   2. echo '<token>' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
    echo "   3. 重跑 ./sync-gitee-all.sh"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 正式版、最早的在前：第一次推 tag 会把整段历史一起带过去，所以旧版先走。
TAGS="$(gh release list --limit 200 --json tagName,isDraft,isPrerelease \
    --jq '[.[] | select(.isDraft | not) | select(.isPrerelease | not) | .tagName] | reverse | .[]')"
if [ -z "$TAGS" ]; then
    echo "✗ 没读到 GitHub 上的 release（gh 登录了吗？）" >&2
    exit 1
fi

SYNCED=0
SKIPPED=0
FAILED=""

for TAG in $TAGS; do
    ID="$(curl -sS "$API/releases/tags/$TAG?access_token=$TOKEN" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    if [ -n "$ID" ]; then
        echo "· $TAG 已在 Gitee，跳过"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    DIR="$WORK/$TAG"
    mkdir -p "$DIR"
    if ! gh release download "$TAG" --pattern '*.dmg' --dir "$DIR" > /dev/null 2>&1; then
        echo "✗ $TAG 没有 dmg 附件，跳过" >&2
        FAILED="$FAILED $TAG"
        continue
    fi

    DMG="$(ls "$DIR"/*.dmg | head -1)"
    if ./sync-gitee-release.sh "$TAG" "$DMG"; then
        SYNCED=$((SYNCED + 1))
    else
        FAILED="$FAILED $TAG"
    fi
done

echo "✓ 完成：新同步 $SYNCED 个，已存在 $SKIPPED 个${FAILED:+，失败:$FAILED}"
[ -z "$FAILED" ]
