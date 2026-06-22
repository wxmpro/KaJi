#!/bin/bash
# package_dmg.sh — 编译 KaJi.app + 打包成 DMG
#
# 用法：
#   ./scripts/package_dmg.sh                                       # Debug 配置 + ad-hoc 签名
#   ./scripts/package_dmg.sh --release                             # Release 配置
#   ./scripts/package_dmg.sh --sign "Developer ID Application: Your Name (TEAMID)" --release
#   ./scripts/package_dmg.sh --notarize \
#       --apple-id you@example.com \
#       --team-id ABCDE12345 \
#       --password xxxx-xxxx-xxxx-xxxx
#
# 设计原则：
#   - 零第三方依赖（只用 macOS 自带的 hdiutil / codesign / xcrun notarytool）
#   - staging 目录只放 .app 和 Applications/ 软链接（不拷贝项目其他文件）
#   - 永远不包含 ~/Library/Application Support/KaJi/（用户数据在系统目录）
#   - DMG 文件名带版本号（读 MARKETING_VERSION）：dist/KaJi-vX.Y.Z.dmg
#   - 失败时清理 staging 目录
#
# 不用 sudo。不修改 xcode-select（用 DEVELOPER_DIR 环境变量绕开）。

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="KaJi"
SCHEME="KaJi"
CONFIGURATION="Debug"
DERIVED_DATA="$PROJECT_DIR/build/derived-dmg"
STAGING_DIR="$PROJECT_DIR/build/staging-dmg"
DIST_DIR="$PROJECT_DIR/dist"
SIGN_IDENTITY="-"   # 默认 ad-hoc 签名；传 --sign 改 Developer ID
NOTARIZE=0
NOTARIZE_APPLE_ID=""
NOTARIZE_TEAM_ID=""
NOTARIZE_PASSWORD=""
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --release) CONFIGURATION="Release" ;;
    --sign)
      shift
      SIGN_IDENTITY="$1"
      ;;
    --notarize) NOTARIZE=1 ;;
    --apple-id)
      shift
      NOTARIZE_APPLE_ID="$1"
      ;;
    --team-id)
      shift
      NOTARIZE_TEAM_ID="$1"
      ;;
    --password)
      shift
      NOTARIZE_PASSWORD="$1"
      ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

# 读版本号（MARKETING_VERSION from project.pbxproj build settings，在 xcodegen 之后读取）
VERSION=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -showBuildSettings \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+MARKETING_VERSION / {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
if [ -z "$VERSION" ]; then
  echo "[FAIL] 无法读取 MARKETING_VERSION" >&2
  exit 1
fi
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"

# 读版本号（在 xcodegen 之后从刷新的 pbxproj 读，避免读到旧值）
if [ "$SKIP_BUILD" = "1" ]; then
  echo "==> 1/7 xcodegen generate [SKIP]"
  echo "==> 2/7 xcodebuild ${CONFIGURATION} [SKIP]"
else
  echo "==> 1/7 xcodegen generate"
  xcodegen generate
fi

VERSION=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -showBuildSettings \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+MARKETING_VERSION / {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
if [ -z "$VERSION" ]; then
  echo "[FAIL] 无法读取 MARKETING_VERSION" >&2
  exit 1
fi
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
echo "    -> 版本号: $VERSION, DMG: $DMG_NAME"

if [ "$SKIP_BUILD" = "1" ]; then
  # .app 已由 CI 上一步 build 好；CI 把 .app 复制到脚本默认 DERIVED_DATA 路径
  :
else
  echo "==> 2/7 xcodebuild ${CONFIGURATION}"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
      -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      -destination "platform=macOS,arch=arm64" \
      build 2>&1 | tail -8
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "[FAIL] 编译失败: $APP_PATH 不存在" >&2
  exit 1
fi
echo "    -> $APP_PATH"

echo "==> 3/7 准备 staging 目录（只放 .app + Applications 软链接）"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
echo "    -> $STAGING_DIR"

echo "==> 4/7 代码签名 ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "    -> ad-hoc 签名（不签名也可启动，但 Gatekeeper 会拦）"
else
  echo "    -> Developer ID: $SIGN_IDENTITY"
fi
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$STAGING_DIR/$APP_NAME.app"
codesign --verify --verbose=2 "$STAGING_DIR/$APP_NAME.app"

echo "==> 5/7 hdiutil 打包 DMG"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
echo "    -> $DMG_PATH"

echo "==> 6/7 清理 staging"
rm -rf "$STAGING_DIR"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> 7/7 公证 + 装订"
  if [ -z "$NOTARIZE_APPLE_ID" ] || [ -z "$NOTARIZE_TEAM_ID" ] || [ -z "$NOTARIZE_PASSWORD" ]; then
    echo "[FAIL] 公证需要 --apple-id / --team-id / --password" >&2
    exit 1
  fi
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$NOTARIZE_APPLE_ID" \
    --team-id "$NOTARIZE_TEAM_ID" \
    --password "$NOTARIZE_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  echo "    -> 公证 + 装订完成"
else
  echo "==> 7/7 跳过公证（ad-hoc / 未签名分发会触发 Gatekeeper；分发前用 --notarize）"
fi

echo ""
echo "Done."
echo "DMG: $DMG_PATH"
ls -lh "$DMG_PATH" | awk '{print "    大小:", $5}'
