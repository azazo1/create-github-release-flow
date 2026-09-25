#!/usr/bin/env bash

# 生成当前平台的发布产物 (Node.js / TypeScript), 复制到项目 scripts/dist.sh.
# 需要同时复制 scripts/archive.sh, scripts/build-version.sh 与 src/version.ts.
#
# 只改下面几个变量:
PROJECT_NAME="PROJECT"
ENTRY="src/cli.ts"
BINARY_NAME="PROJECT"
# 冒烟检查用的参数, 要求产物能报出版本号.
SMOKE_ARGS=(--version)
# 打包器, 缺省 bun build --compile 出单文件可执行产物.
BUNDLER="${BUNDLER:-bun}"

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

platform="$(node -p 'process.platform')"
arch="$(node -p 'process.arch')"
case "$platform" in
  darwin) platform="macos" ;;
  linux) platform="linux" ;;
  win32) platform="windows" ;;
esac
case "$arch" in
  x64) arch="x86_64" ;;
  arm64) arch="aarch64" ;;
esac

version="${PROJECT_BUILD_VERSION:-}"
if [[ -z "$version" ]]; then
  version="v$(bash scripts/build-version.sh)"
fi

echo "构建 $PROJECT_NAME $version ($platform-$arch)"

binary="$BINARY_NAME"
if [[ "$platform" == "windows" ]]; then
  binary="$BINARY_NAME.exe"
fi

staging="dist/stage"
rm -rf "$staging"
mkdir -p "$staging"

case "$BUNDLER" in
  bun)
    bun build "$ENTRY" \
      --compile \
      --outfile "$staging/$binary" \
      --define "BUILD_VERSION=\"$version\""
    ;;
  esbuild)
    esbuild "$ENTRY" \
      --bundle \
      --platform=node \
      --outfile "$staging/$binary" \
      --define:BUILD_VERSION="\"$version\""
    chmod +x "$staging/$binary"
    ;;
  *)
    echo "不支持的打包器: $BUNDLER" >&2
    exit 1
    ;;
esac

reported="$("$staging/$binary" "${SMOKE_ARGS[@]}")"
if [[ "$reported" != *"$version"* ]]; then
  echo "版本号校验失败: 期望 $version, 实际输出 $reported" >&2
  exit 1
fi
echo "版本号校验通过: $version"

PROJECT_NAME="$PROJECT_NAME" \
PROJECT_BUILD_VERSION="$version" \
TARGET_PLATFORM="$platform" \
TARGET_ARCH="$arch" \
  bash scripts/archive.sh "$staging" "$binary"
