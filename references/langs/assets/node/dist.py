#!/usr/bin/env python3

# 生成当前平台的发布产物 (Node.js / TypeScript), 复制到项目 scripts/dist.py.
# 需要同时复制 scripts/archive.py, scripts/build-version.py, scripts/release_common.py 与 src/version.ts.

import json
import os

import release_common as rc

# 只改下面几个常量:
PROJECT_NAME = "PROJECT"
ENTRY = "src/cli.ts"
BINARY_NAME = "PROJECT"
# 打包器, 缺省 bun build --compile 出单文件可执行产物.
BUNDLER = os.environ.get("BUNDLER", "bun")
# 冒烟检查用的参数, 要求产物能报出版本号.
SMOKE_ARGS = ["--version"]


def package_version_fallback():
    """仓库还没有版本 tag 时, 用 package.json 的 version 兜底; 读不到就返回 None."""
    try:
        with open("package.json", encoding="utf-8") as handle:
            return json.load(handle).get("version")
    except (OSError, ValueError):
        return None


def main():
    rc.configure_output_encoding()
    rc.repo_root()

    # bun build --compile 只能出当前平台的产物, 所以这里不看 TARGET_PLATFORM / TARGET_ARCH.
    target_platform = rc.detect_platform()
    target_arch = rc.detect_arch()
    display_version, archive_version = rc.resolve_versions(
        rc.script_path("build-version.py"), package_version_fallback
    )
    print(f"构建 {PROJECT_NAME} {display_version} ({target_platform}-{target_arch})")

    binary = BINARY_NAME + (".exe" if target_platform == "windows" else "")
    staging = rc.stage_dir()
    binary_path = os.path.join(staging, binary)

    if BUNDLER == "bun":
        rc.run(
            [
                "bun",
                "build",
                ENTRY,
                "--compile",
                "--outfile",
                binary_path,
                "--define",
                f'BUILD_VERSION="{display_version}"',
            ],
            capture=False,
        )
    elif BUNDLER == "esbuild":
        rc.run(
            [
                "esbuild",
                ENTRY,
                "--bundle",
                "--platform=node",
                "--outfile",
                binary_path,
                f'--define:BUILD_VERSION="{display_version}"',
            ],
            capture=False,
        )
        os.chmod(binary_path, 0o755)
    else:
        rc.die(f"不支持的打包器: {BUNDLER}")

    rc.smoke_check([binary_path], SMOKE_ARGS, display_version)
    rc.archive(
        staging,
        [binary],
        PROJECT_NAME,
        archive_version,
        target=(target_platform, target_arch),
    )


if __name__ == "__main__":
    main()
