#!/usr/bin/env bash

# 生成当前平台的发布产物 (Python 二进制形态), 复制到项目 scripts/dist.sh.
# 需要同时复制 scripts/archive.sh, scripts/build-version.sh 与 _build_version.py.
# 库分发 (wheel) 不需要这个脚本, 用项目的构建与发布入口即可.
#
# 只改下面几个变量:
PROJECT_NAME="PROJECT"
PACKAGE_DIR="src/PROJECT"
# PyInstaller 的入口必须是绝对导入的启动脚本, 不能用包内的 __main__.py:
# 后者被当作顶层 __main__ 执行时相对导入会失败. 复制 assets/python/entry.py 到 scripts/.
ENTRY="scripts/entry.py"
# 包所在的那一层目录, 供 PyInstaller 解析绝对导入.
PACKAGE_PATH="${PACKAGE_PATH:-src}"
BINARY_NAME="PROJECT"
# 冒烟检查用的参数, 要求产物能报出版本号.
SMOKE_ARGS=(--version)
# pyinstaller (生产推荐, 需要已安装 pyinstaller) 或 zipapp (只用标准库, 仅 Unix).
BUILD_MODE="${BUILD_MODE:-pyinstaller}"
# zipapp 模式的源码根与入口: 源码根是包含包目录的那一层, 入口写 <包名>.__main__:main.
ZIPAPP_SOURCE="${ZIPAPP_SOURCE:-src}"
ZIPAPP_MAIN="${ZIPAPP_MAIN:-PROJECT.__main__:main}"
PYTHON="${PYTHON:-python3}"

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

platform="$("$PYTHON" -c 'import platform; print(platform.system())')"
arch="$("$PYTHON" -c 'import platform; print(platform.machine())')"
case "$platform" in
  Darwin) platform="macos" ;;
  Linux) platform="linux" ;;
  Windows) platform="windows" ;;
esac
case "$arch" in
  x86_64 | AMD64) arch="x86_64" ;;
  arm64 | aarch64) arch="aarch64" ;;
esac

version="${PROJECT_BUILD_VERSION:-}"
if [[ -z "$version" ]]; then
  version="v$(bash scripts/build-version.sh)"
fi

echo "构建 $PROJECT_NAME $version ($platform-$arch)"

staging="dist/stage"
rm -rf "$staging"
mkdir -p "$staging"

# 版本号在构建期写入源码包, 这样冻结进二进制的版本号与运行时读到的完全一致.
printf 'BUILD_VERSION = "%s"\n' "$version" > "$PACKAGE_DIR/_generated_version.py"

case "$BUILD_MODE" in
  pyinstaller)
    "$PYTHON" -m PyInstaller \
      --onefile \
      --clean \
      --name "$BINARY_NAME" \
      --paths "$PACKAGE_PATH" \
      --distpath "$staging" \
      --workpath "dist/pyinstaller/build" \
      --specpath "dist/pyinstaller" \
      "$ENTRY"
    ;;
  zipapp)
    if [[ "$platform" == "windows" ]]; then
      echo "zipapp 模式不支持 Windows 目标, 请改用 pyinstaller" >&2
      exit 1
    fi
    "$PYTHON" -m zipapp "$ZIPAPP_SOURCE" \
      --main "$ZIPAPP_MAIN" \
      --python "/usr/bin/env python3" \
      --output "$staging/$BINARY_NAME"
    chmod +x "$staging/$BINARY_NAME"
    ;;
  *)
    echo "不支持的构建方式: $BUILD_MODE" >&2
    exit 1
    ;;
esac

reported="$("$staging/$BINARY_NAME" "${SMOKE_ARGS[@]}")"
if [[ "$reported" != *"$version"* ]]; then
  echo "版本号校验失败: 期望 $version, 实际输出 $reported" >&2
  exit 1
fi
echo "版本号校验通过: $version"

PROJECT_NAME="$PROJECT_NAME" \
PROJECT_BUILD_VERSION="$version" \
TARGET_PLATFORM="$platform" \
TARGET_ARCH="$arch" \
  bash scripts/archive.sh "$staging" "$BINARY_NAME"
