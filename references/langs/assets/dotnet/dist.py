#!/usr/bin/env python3

# 生成当前平台的发布产物 (C# / .NET), 复制到项目 scripts/dist.py.
# 需要同时复制 scripts/archive.py, scripts/build-version.py, scripts/release_common.py 与 Directory.Build.props.

import os

import release_common as rc

# 只改下面几个常量:
PROJECT_NAME = "PROJECT"
PROJECT_FILE = "src/PROJECT/PROJECT.csproj"
BINARY_NAME = "PROJECT"
# 冒烟检查用的参数, 要求产物能报出版本号.
SMOKE_ARGS = ["--version"]
# self-contained 出带平台架构后缀的 RID 二进制, framework-dependent 出平台无关的 dll 程序集.
BUILD_MODE = os.environ.get("BUILD_MODE", "self-contained")
# 交叉发布时显式指定 RID, 缺省按当前平台与架构推导.
RID = os.environ.get("RID", "")

RID_BY_TARGET = {
    ("linux", "x86_64"): "linux-x64",
    ("linux", "aarch64"): "linux-arm64",
    ("macos", "x86_64"): "osx-x64",
    ("macos", "aarch64"): "osx-arm64",
    ("windows", "x86_64"): "win-x64",
    ("windows", "aarch64"): "win-arm64",
}


def package_version_fallback():
    """仓库还没有版本 tag 时, 用 MSBuild 求值出的包版本兜底; 读不到就返回 None."""
    return rc.try_run(["dotnet", "msbuild", PROJECT_FILE, "-getProperty:Version"])


def main():
    rc.configure_output_encoding()
    rc.repo_root()

    target_platform = rc.target_platform()
    target_arch = rc.target_arch()
    display_version, archive_version = rc.resolve_versions(
        rc.script_path("build-version.py"), package_version_fallback
    )
    print(f"构建 {PROJECT_NAME} {display_version} ({target_platform}-{target_arch})")

    staging = rc.stage_dir()
    publish_args = [
        "dotnet",
        "publish",
        PROJECT_FILE,
        "-c",
        "Release",
        "-o",
        staging,
        f"-p:PROJECT_BUILD_VERSION={display_version}",
    ]

    if BUILD_MODE == "self-contained":
        rid = RID or RID_BY_TARGET.get((target_platform, target_arch))
        if not rid:
            rc.die(f"无法为 {target_platform}-{target_arch} 推导 RID, 请显式设置 RID")
        publish_args += ["--self-contained", "true", "-r", rid]
        binary = BINARY_NAME + (".exe" if target_platform == "windows" else "")
    elif BUILD_MODE == "framework-dependent":
        publish_args += ["--self-contained", "false"]
        binary = f"{BINARY_NAME}.dll"
    else:
        rc.die(f"不支持的构建方式: {BUILD_MODE}")

    rc.run(publish_args, capture=False)

    binary_path = os.path.join(staging, binary)
    if BUILD_MODE == "self-contained":
        # self-contained 是原生可执行文件, 直接运行; 用 dotnet <exe> 会把它当成托管程序集而失败.
        rc.smoke_check([binary_path], SMOKE_ARGS, display_version)
        rc.archive(
            staging,
            [binary],
            PROJECT_NAME,
            archive_version,
            target=(target_platform, target_arch),
        )
    else:
        # 框架依赖的程序集与平台无关, 按 PROJECT-VERSION.EXT 命名.
        rc.smoke_check(["dotnet", binary_path], SMOKE_ARGS, display_version)
        rc.archive(
            staging,
            [],
            PROJECT_NAME,
            archive_version,
            platform_independent=True,
        )


if __name__ == "__main__":
    main()
