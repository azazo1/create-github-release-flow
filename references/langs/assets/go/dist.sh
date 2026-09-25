#!/usr/bin/env bash

# 生成当前平台的发布产物 (Go), 复制到项目 scripts/dist.sh.
# 需要同时复制 scripts/archive.sh 与 scripts/build-version.sh.
#
# 只改下面几个变量:
PROJECT_NAME="PROJECT"
MAIN_PACKAGE="./cmd/PROJECT"
BINARY_NAME="PROJECT"
# 冒烟检查用的参数, 要求二进制能报出版本号.
SMOKE_ARGS=(--version)

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

platform="$(go env GOOS)"
arch="$(go env GOARCH)"
case "$platform" in
  darwin) platform="macos" ;;
  linux) platform="linux" ;;
  windows) platform="windows" ;;
esac
case "$arch" in
  amd64) arch="x86_64" ;;
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

# 注入路径必须是完整包路径, 所以这里用 go list -m 取当前模块名.
module="$(go list -m)"
CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X ${module}/internal/buildinfo.version=$version" \
  -o "$staging/$binary" \
  "$MAIN_PACKAGE"

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
