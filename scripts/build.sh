#!/bin/bash
# build.sh — 编译 KaJi.app + 安装 + 启动 + 截屏
#
# 用法：
#   ./scripts/build.sh             # 编译 + 安装 + 启动
#   ./scripts/build.sh --no-run    # 编译 + 安装，不启动
#   ./scripts/build.sh --shoot     # 编译 + 安装 + 启动 + 截屏到 screenshots/
#   ./scripts/build.sh --no-run --shoot  # 只编译 + 安装 + 截屏（不启动）
#
# 不用 sudo。不修改 xcode-select（用 DEVELOPER_DIR 环境变量绕开）。
# 覆盖式安装：每次 build 直接替换 ~/Applications/KaJi.app 里的内容。
# 所有截图统一存到 <project>/screenshots/，不污染 build/ 目录。

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="KaJi"
SCHEME="KaJi"
DERIVED_DATA="$PROJECT_DIR/build/derived"
BUILD_OUTPUT="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
INSTALL_PATH="$HOME/Applications/$APP_NAME.app"
SCREENSHOTS_DIR="$PROJECT_DIR/screenshots"
RUN_AFTER=1
SHOOT=0

for arg in "$@"; do
  case "$arg" in
    --no-run) RUN_AFTER=0 ;;
    --shoot) SHOOT=1 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$SCREENSHOTS_DIR"

echo "==> 1/4 xcodegen generate"
xcodegen generate

echo "==> 2/4 xcodebuild (Xcode 26 完整版, DEVELOPER_DIR 绕开 sudo)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=arm64" \
    build 2>&1 | tail -8

if [ ! -d "$BUILD_OUTPUT" ]; then
  echo "[FAIL] 编译失败: $BUILD_OUTPUT 不存在" >&2
  exit 1
fi
echo "    -> 编译产物: ${BUILD_OUTPUT}"

echo "==> 3/4 安装到 ${INSTALL_PATH} (覆盖式)"
mkdir -p "$HOME/Applications"
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_PATH"
cp -R "$BUILD_OUTPUT" "$INSTALL_PATH"
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f -R -trusted "$INSTALL_PATH" 2>&1 | tail -2 || true
echo "    -> 安装完成: ${INSTALL_PATH}"

if [ "$RUN_AFTER" = "1" ]; then
  echo "==> 4/4 启动 ${APP_NAME}"
  open "$INSTALL_PATH"
  sleep 1
  ps aux | grep "$APP_NAME.app/Contents/MacOS/$APP_NAME" | grep -v grep | awk '{printf "    -> PID %s  %s\n", $2, $11}'
fi

if [ "$SHOOT" = "1" ]; then
  echo "==> 5/5 截屏到 $SCREENSHOTS_DIR"
  TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
  SCREENSHOT_PATH="$SCREENSHOTS_DIR/${TIMESTAMP}.png"
  sleep 1   # 等窗口绘制
  screencapture -x "$SCREENSHOT_PATH"
  echo "    -> 截图: ${SCREENSHOT_PATH}"
fi

echo ""
echo "Done."
if [ "$RUN_AFTER" = "1" ]; then
  echo "重启: open ${INSTALL_PATH}"
fi
