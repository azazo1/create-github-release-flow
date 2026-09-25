#!/usr/bin/env bash

# 生成当前平台的发布产物 (C# / .NET), 复制到项目 scripts/dist.sh.
# 需要同时复制 scripts/archive.sh, scripts/build-version.sh 与 Directory.Build.props.
#
# 只改下面几个变量:
PROJECT_NAME="PROJECT"
PROJECT_FILE="src/PROJECT/PROJECT.csproj"
BINARY_NAME="PROJECT"
# 冒烟检查用的参数, 要求产物能报出版本号.
SMOKE_ARGS=(--version)
# self-contained 出带平台架构后缀的 RID 二进制, framework-dependent 出平台无关的 dll 程序集.
BUILD_MODE="${BUILD_MODE:-self-contained}"
# 交叉发布时显式指定 RID, 缺省按当前平台与架构推导.
RID="${RID:-}"

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

platform="$(dotnet --info | awk -F': *' '/RID:/ {print $2; exit}')"
case "$platform" in
  linux-*) platform="linux" ;;
  osx-*) platform="macos" ;;
  win-*) platform="windows" ;;
esac
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch="x86_64" ;;
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

publish_args=(publish "$PROJECT_FILE" -c Release -o "$staging" "-p:PROJECT_BUILD_VERSION=$version")

if [[ "$BUILD_MODE" == "self-contained" ]]; then
  if [[ -z "$RID" ]]; then
    case "$platform-$arch" in
      linux-x86_64) RID="linux-x64" ;;
      linux-aarch64) RID="linux-arm64" ;;
      macos-x86_64) RID="osx-x64" ;;
      macos-aarch64) RID="osx-arm64" ;;
      windows-x86_64) RID="win-x64" ;;
      windows-aarch64) RID="win-arm64" ;;
      *)
        echo "无法为 $platform-$arch 推导 RID, 请显式设置 RID" >&2
        exit 1
        ;;
    esac
  fi
  publish_args+=(--self-contained true -r "$RID")
  binary="$BINARY_NAME"
  if [[ "$platform" == "windows" ]]; then
    binary="$BINARY_NAME.exe"
  fi
else
  publish_args+=(--self-contained false)
  binary="$BINARY_NAME.dll"
fi

dotnet "${publish_args[@]}"

if [[ "$BUILD_MODE" == "self-contained" ]]; then
  # self-contained 是原生可执行文件, 直接运行; 用 dotnet <exe> 会把它当成托管程序集而失败.
  reported="$("$staging/$binary" "${SMOKE_ARGS[@]}")"
else
  reported="$(dotnet "$staging/$binary" "${SMOKE_ARGS[@]}")"
fi
if [[ "$reported" != *"$version"* ]]; then
  echo "版本号校验失败: 期望 $version, 实际输出 $reported" >&2
  exit 1
fi
echo "版本号校验通过: $version"

if [[ "$BUILD_MODE" == "self-contained" ]]; then
  PROJECT_NAME="$PROJECT_NAME" \
  PROJECT_BUILD_VERSION="$version" \
  TARGET_PLATFORM="$platform" \
  TARGET_ARCH="$arch" \
    bash scripts/archive.sh "$staging" "$binary"
else
  # 框架依赖的程序集与平台无关, 按 PROJECT-VERSION.EXT 命名.
  PROJECT_NAME="$PROJECT_NAME" \
  PROJECT_BUILD_VERSION="$version" \
  PLATFORM_INDEPENDENT=1 \
    bash scripts/archive.sh "$staging"
fi
