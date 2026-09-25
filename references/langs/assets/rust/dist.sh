#!/usr/bin/env bash

# 生成当前平台的发布产物 (Rust), 复制到项目 scripts/dist.sh.
# 需要同时复制 scripts/archive.sh, scripts/build-version.sh 与 build.rs.
#
# 只改下面几个变量:
PROJECT_NAME="PROJECT"
BINARY_NAME="PROJECT"
# 冒烟检查用的参数, 要求二进制能报出版本号.
SMOKE_ARGS=(--version)
# 需要交叉编译时设置, 例如 aarch64-unknown-linux-musl;
# 交叉编译的产物无法本机执行, 只能做文件格式检查, 并用 TARGET_PLATFORM / TARGET_ARCH 命名.
RUST_TARGET="${RUST_TARGET:-}"

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

detect_platform() {
  case "$(uname -s)" in
    Linux) printf 'linux\n' ;;
    Darwin) printf 'macos\n' ;;
    MINGW* | MSYS* | CYGWIN*) printf 'windows\n' ;;
    *) echo "无法识别平台 $(uname -s), 请显式设置 TARGET_PLATFORM" >&2; return 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64\n' ;;
    arm64 | aarch64) printf 'aarch64\n' ;;
    *) echo "无法识别架构 $(uname -m), 请显式设置 TARGET_ARCH" >&2; return 1 ;;
  esac
}

platform="${TARGET_PLATFORM:-$(detect_platform)}"
arch="${TARGET_ARCH:-$(detect_arch)}"

version="${PROJECT_BUILD_VERSION:-}"
if [[ -z "$version" ]]; then
  version="v$(bash scripts/build-version.sh)"
fi

echo "构建 $PROJECT_NAME $version ($platform-$arch)"

cargo_args=(build --release --locked)
if [[ -n "$RUST_TARGET" ]]; then
  cargo_args+=(--target "$RUST_TARGET")
fi
cargo "${cargo_args[@]}"

binary="$BINARY_NAME"
if [[ "$platform" == "windows" ]]; then
  binary="$BINARY_NAME.exe"
fi

build_dir="target/release"
if [[ -n "$RUST_TARGET" ]]; then
  build_dir="target/$RUST_TARGET/release"
fi

staging="dist/stage"
rm -rf "$staging"
mkdir -p "$staging"
cp "$build_dir/$binary" "$staging/$binary"

if [[ -n "$RUST_TARGET" ]]; then
  echo "交叉编译产物无法本机执行, 只检查文件格式"
  file "$staging/$binary"
else
  reported="$("$staging/$binary" "${SMOKE_ARGS[@]}")"
  if [[ "$reported" != *"$version"* ]]; then
    echo "版本号校验失败: 期望 $version, 实际输出 $reported" >&2
    exit 1
  fi
  echo "版本号校验通过: $version"
fi

PROJECT_NAME="$PROJECT_NAME" \
PROJECT_BUILD_VERSION="$version" \
TARGET_PLATFORM="$platform" \
TARGET_ARCH="$arch" \
  bash scripts/archive.sh "$staging" "$binary"
