#!/usr/bin/env python3

# 生成当前平台的发布产物 (Python 二进制形态), 复制到项目 scripts/dist.py.
# 需要同时复制 scripts/archive.py, scripts/build-version.py, scripts/release_common.py 与 _build_version.py.
# 库分发 (wheel) 不需要这个脚本, 用项目的构建与发布入口即可.

import importlib.metadata
import os
import sys

import release_common as rc

# 只改下面几个常量:
PROJECT_NAME = "PROJECT"
# 分发的包名, 读包版本兜底时用.
PACKAGE_NAME = "PROJECT"
PACKAGE_DIR = "src/PROJECT"
# PyInstaller 的入口必须是绝对导入的启动脚本, 不能用包内的 __main__.py:
# 后者被当作顶层 __main__ 执行时相对导入会失败. 复制 assets/python/entry.py 到 scripts/.
ENTRY = "scripts/entry.py"
# 包所在的那一层目录, 供 PyInstaller 解析绝对导入.
PACKAGE_PATH = os.environ.get("PACKAGE_PATH", "src")
BINARY_NAME = "PROJECT"
# 冒烟检查用的参数, 要求产物能报出版本号.
SMOKE_ARGS = ["--version"]
# pyinstaller (生产推荐, 需要已安装 pyinstaller) 或 zipapp (只用标准库, 仅 Unix).
BUILD_MODE = os.environ.get("BUILD_MODE", "pyinstaller")
# zipapp 模式的源码根与入口: 源码根是包含包目录的那一层, 入口写 <包名>.__main__:main.
ZIPAPP_SOURCE = os.environ.get("ZIPAPP_SOURCE", "src")
ZIPAPP_MAIN = os.environ.get("ZIPAPP_MAIN", "PROJECT.__main__:main")


def package_version_fallback():
    """仓库还没有版本 tag 时用包版本兜底: 先读 pyproject.toml, 再退回已安装的 metadata."""
    try:
        import tomllib
    except ImportError:
        tomllib = None

    try:
        if tomllib is not None:
            with open("pyproject.toml", "rb") as handle:
                version = tomllib.load(handle).get("project", {}).get("version")
            if version:
                return version
        return importlib.metadata.version(PACKAGE_NAME)
    except (OSError, KeyError, ValueError, ImportError):
        return None


def main():
    rc.configure_output_encoding()
    rc.repo_root()

    # PyInstaller 与 zipapp 都只能出当前平台的产物, 所以这里不看 TARGET_PLATFORM / TARGET_ARCH.
    target_platform = rc.detect_platform()
    target_arch = rc.detect_arch()
    display_version, archive_version = rc.resolve_versions(
        rc.script_path("build-version.py"), package_version_fallback
    )
    print(f"构建 {PROJECT_NAME} {display_version} ({target_platform}-{target_arch})")

    staging = rc.stage_dir()

    # 版本号在构建期写入源码包, 这样冻结进二进制的版本号与运行时读到的完全一致.
    if not os.path.isdir(PACKAGE_DIR):
        rc.die(f"PACKAGE_DIR 不存在: {PACKAGE_DIR}; 请把它指向包目录 (例如 src/<包名>)")
    with open(os.path.join(PACKAGE_DIR, "_generated_version.py"), "w", encoding="utf-8") as handle:
        handle.write(f'BUILD_VERSION = "{display_version}"\n')

    if BUILD_MODE == "pyinstaller":
        rc.run(
            [
                sys.executable,
                "-m",
                "PyInstaller",
                "--onefile",
                "--clean",
                "--name",
                BINARY_NAME,
                "--paths",
                PACKAGE_PATH,
                "--distpath",
                staging,
                "--workpath",
                "dist/pyinstaller/build",
                "--specpath",
                "dist/pyinstaller",
                ENTRY,
            ],
            capture=False,
        )
        binary = BINARY_NAME + (".exe" if target_platform == "windows" else "")
    elif BUILD_MODE == "zipapp":
        if target_platform == "windows":
            rc.die("zipapp 模式不支持 Windows 目标, 请改用 pyinstaller")
        binary = BINARY_NAME
        rc.run(
            [
                sys.executable,
                "-m",
                "zipapp",
                ZIPAPP_SOURCE,
                "--main",
                ZIPAPP_MAIN,
                "--python",
                "/usr/bin/env python3",
                "--output",
                os.path.join(staging, binary),
            ],
            capture=False,
        )
        os.chmod(os.path.join(staging, binary), 0o755)
    else:
        rc.die(f"不支持的构建方式: {BUILD_MODE}")

    binary_path = os.path.join(staging, binary)
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
