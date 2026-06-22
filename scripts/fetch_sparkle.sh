#!/bin/bash
# fetch_sparkle.sh — 下载 Sparkle 2.x Release tar.xz 并解压到 build/sparkle/
#
# CI 与本地都用。SPM 拉的是 Sparkle 源代码，但 sign_update 工具（用于签 DMG）
# 在 Sparkle 的 Release 资产 tar.xz 里，所以需要单独下载。
#
# 用法：
#   ./scripts/fetch_sparkle.sh
#   SPARKLE_VERSION=2.7.0 ./scripts/fetch_sparkle.sh
#
# 设计：
#   - 默认版本与 project.yml 的 Sparkle.from 保持一致
#   - 解压到 build/sparkle/（git ignored），避免污染源码目录

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.7.0}"
SPARKLE_DEST="$PROJECT_DIR/build/sparkle"

# GitHub release 直链（Sparkle 2.x 的 tar.xz 资产）
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

echo "[fetch_sparkle] 下载 Sparkle $SPARKLE_VERSION ..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP/sparkle.tar.xz"

mkdir -p "$SPARKLE_DEST"
tar -xJf "$TMP/sparkle.tar.xz" -C "$SPARKLE_DEST" --strip-components=1

# 校验 sign_update 工具就位
if [ ! -x "$SPARKLE_DEST/bin/sign_update" ]; then
  echo "[fetch_sparkle][FAIL] sign_update 工具未找到: $SPARKLE_DEST/bin/sign_update" >&2
  exit 1
fi

echo "[fetch_sparkle][OK] Sparkle $SPARKLE_VERSION -> $SPARKLE_DEST"
"$SPARKLE_DEST/bin/sign_update" --version 2>/dev/null || true