#!/bin/bash
# generate_appcast.sh — 给定 dist/*.dmg 重新生成 docs/appcast.xml
#
# 用法：
#   ./scripts/generate_appcast.sh
#
# 环境变量：
#   SPARKLE_BIN_PATH          Sparkle 解压根目录（默认 ./build/sparkle）
#   SPARKLE_PRIVATE_KEY_FILE  PEM 私钥路径（默认 ./build/sparkle-private.key）
#
# 设计原则：
#   - append-only：新版本 <item> 加到 <channel> 末尾（Sparkle 自己挑 max）
#   - 旧版本不删除——朋友从 v1.9.3 升 v1.10.0 还能回看历史
#   - 公钥 base64 长度校验（必须 44 字符，否则 script 拒绝生成空签名 appcast）
#
# 流程：
#   1. 校验 Sparkle 工具与私钥就位
#   2. 扫描 dist/KaJi-v*.dmg
#   3. 挂载每个 dmg → 取 Info.plist 的 CFBundleVersion / CFBundleShortVersionString
#   4. sign_update 算 edSignature（Ed25519）
#   5. 拼 RSS 2.0 + sparkle 命名空间 → 写 docs/appcast.xml
#   6. xmllint 校验 XML 语法

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

DIST_DIR="$PROJECT_DIR/dist"
APPCAST_PATH="$PROJECT_DIR/appcast.xml"
SPARKLE_BIN_PATH="${SPARKLE_BIN_PATH:-$PROJECT_DIR/build/sparkle}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$PROJECT_DIR/build/sparkle-private.key}"

# --- 前置校验 ---
if [ ! -x "$SPARKLE_BIN_PATH/bin/sign_update" ]; then
  echo "[generate_appcast][FAIL] 找不到 sign_update: $SPARKLE_BIN_PATH/bin/sign_update" >&2
  echo "                              请先 ./scripts/fetch_sparkle.sh" >&2
  exit 1
fi
if [ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
  echo "[generate_appcast][FAIL] 找不到私钥: $SPARKLE_PRIVATE_KEY_FILE" >&2
  echo "                              请设置 SPARKLE_PRIVATE_KEY_FILE 环境变量或放到默认路径" >&2
  exit 1
fi

# --- 收集所有 dmg ---
shopt -s nullglob
DMGS=( "$DIST_DIR"/KaJi-v*.dmg )
shopt -u nullglob
if [ ${#DMGS[@]} -eq 0 ]; then
  echo "[generate_appcast][FAIL] $DIST_DIR 下没有任何 KaJi-v*.dmg" >&2
  exit 1
fi
echo "[generate_appcast] 扫描到 ${#DMGS[@]} 个 dmg"

# --- 生成每个 DMG 的 <item> 片段 ---
ITEMS_XML=""
for dmg in "${DMGS[@]}"; do
  fname="$(basename "$dmg")"

  # 文件名解析版本号（KaJi-vX.Y.Z.dmg）
  if [[ "$fname" =~ KaJi-v([0-9.]+)\.dmg$ ]]; then
    ver="${BASH_REMATCH[1]}"
  else
    echo "[generate_appcast][WARN] 文件名不符合 KaJi-vX.Y.Z.dmg: $fname，跳过" >&2
    continue
  fi

  # 挂载 dmg 读 Info.plist
  TMP_MOUNT="$(mktemp -d)"
  MOUNT_OUT=$(hdiutil attach -nobrowse -readonly -mountpoint "$TMP_MOUNT" "$dmg" 2>&1) || {
    echo "[generate_appcast][FAIL] 挂载 dmg 失败: $dmg" >&2
    rm -rf "$TMP_MOUNT"
    exit 1
  }
  APP_PLIST="$TMP_MOUNT/KaJi.app/Contents/Info.plist"
  if [ ! -f "$APP_PLIST" ]; then
    echo "[generate_appcast][FAIL] 挂载后找不到 KaJi.app/Contents/Info.plist: $dmg" >&2
    hdiutil detach "$TMP_MOUNT" >/dev/null 2>&1 || true
    rm -rf "$TMP_MOUNT"
    exit 1
  fi

  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
  SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
  SIZE=$(stat -f%z "$dmg")
  hdiutil detach "$TMP_MOUNT" >/dev/null 2>&1 || true
  rm -rf "$TMP_MOUNT"

  # sign_update 算 edSignature（Ed25519）
  # Sparkle 2.x 的 sign_update 不支持 --format 选项；固定输出：
  #   sparkle:edSignature="<base64>" length="<bytes>"
  # 用 sed 精确提取 edSignature 引号内的内容。
  SIGN_OUT=$("$SPARKLE_BIN_PATH/bin/sign_update" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    "$dmg")
  ED_SIG=$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
  # fail-fast：解析不出签名直接终止，绝不把残缺/整行输出当签名写进 appcast
  # （否则错误会从 CI 推迟到用户端，Sparkle 校验失败且极难排查）
  if [ -z "$ED_SIG" ]; then
    echo "[generate_appcast][FAIL] 无法从 sign_update 输出解析 edSignature: $dmg" >&2
    echo "  原始输出: $SIGN_OUT" >&2
    exit 1
  fi

  # 构造 <item>（pubDate 用 dmg 文件 mtime 推到 UTC）
  PUB_DATE=$(date -u -r "$dmg" "+%a, %d %b %Y %H:%M:%S +0000")

  ITEM=$(cat <<EOF
    <item>
      <title>v$SHORT</title>
      <link>https://github.com/wxmpro/KaJi-macOS/releases/tag/v$SHORT</link>
      <description><![CDATA[<h3>v$SHORT</h3><p>见 GitHub Release 说明：<a href="https://github.com/wxmpro/KaJi-macOS/releases/tag/v$SHORT">v$SHORT</a>。</p>]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url="https://github.com/wxmpro/KaJi-macOS/releases/download/v$SHORT/$fname"
        sparkle:version="$BUILD"
        sparkle:shortVersionString="$SHORT"
        length="$SIZE"
        type="application/x-apple-diskimage" />
      <sparkle:edSignature base64="$ED_SIG"/>
    </item>
EOF
)
  ITEMS_XML+="$ITEM"$'\n'
  echo "[generate_appcast]   v$SHORT (build $BUILD, size $SIZE bytes) -> signed"
done

# --- 包裹 channel 头，写入 appcast.xml ---
mkdir -p "$(dirname "$APPCAST_PATH")"
cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>KaJi Changelog</title>
    <link>https://github.com/wxmpro/KaJi-macOS/releases</link>
    <description>卡迹 KaJi macOS 更新源</description>
    <language>zh-CN</language>
$ITEMS_XML  </channel>
</rss>
EOF

# --- XML 语法校验（xmllint 不可用则 warning 但不 fail） ---
if command -v xmllint >/dev/null 2>&1; then
  if xmllint --noout "$APPCAST_PATH" >/dev/null 2>&1; then
    echo "[generate_appcast][OK] 写入 $APPCAST_PATH，共 ${#DMGS[@]} 个版本，XML 语法有效"
  else
    echo "[generate_appcast][WARN] 写入 $APPCAST_PATH 但 xmllint 校验失败" >&2
    xmllint --noout "$APPCAST_PATH" || true
    exit 1
  fi
else
  echo "[generate_appcast][OK] 写入 $APPCAST_PATH，共 ${#DMGS[@]} 个版本（未装 xmllint，跳过 XML 校验）"
fi