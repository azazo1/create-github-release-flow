"""复制到项目源码包内, 例如 src/<package>/_build_version.py, 通常不需要改动.

发行构建时 scripts/dist.sh 会在同目录生成 _generated_version.py 提供版本号, 该文件应当
加入 .gitignore; 日常开发构建没有这个文件, 回落到 dev-build.
"""

try:
    from ._generated_version import BUILD_VERSION
except ImportError:  # 日常开发构建
    BUILD_VERSION = "dev-build"


def version() -> str:
    """返回当前构建应当显示的版本号."""
    return BUILD_VERSION
