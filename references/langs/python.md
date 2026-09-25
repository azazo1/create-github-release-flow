# Python 语言模块

按 SKILL.md 的分派表读取本模块. 这里只写 Python 的落地方式; 流程, release notes 治理, tag 与 release 规则见 SKILL.md, 语言无关的 YAML 骨架见 [workflow-patterns.md](../workflow-patterns.md).

## 分发形态判定

| 形态 | 判定依据 | 套用规则 |
| --- | --- | --- |
| 二进制/应用 | 用户下载单文件可执行产物, 通常由 PyInstaller 或 Nuitka 打包 | 运行时版本号显示, 跨平台归档矩阵, SHA256SUMS |
| 库 | 用户从 PyPI 安装, `pyproject.toml` 有 `[project]` 元数据 | notes-only release, 不打包二进制 |
| 混合 | 既有 `[project.scripts]` 入口又有可导入包 | CLI 走二进制矩阵, 库走 PyPI, 包版本保持一致 |

用 `python -m zipapp` 或 PyInstaller 打出的产物属于二进制分发, 不要与 wheel 混淆.

## 版本来源与 tag 校验

包版本在 `pyproject.toml` 的 `[project].version`; 使用 `dynamic` 时版本由 setuptools-scm 或 hatch-vcs 之类机制生成, 此时以生成结果为准, 不要同时再写一份静态版本. Python 3.11 起可用标准库 `tomllib` 读取:

```yaml
- name: 校验 tag 与包版本
  id: release_version
  if: steps.release_context.outputs.is_release == 'true'
  env:
    TAG_NAME: ${{ steps.release_context.outputs.tag_name }}
  shell: bash
  run: |
    set -euo pipefail
    package_version="$(
      python3 -c 'import tomllib,sys; print(tomllib.load(open("pyproject.toml","rb"))["project"]["version"])'
    )"
    expected_tag="v$package_version"

    if [[ "$TAG_NAME" != "$expected_tag" ]]; then
      echo "tag $TAG_NAME 与包版本 $package_version 不一致" >&2
      exit 1
    fi

    echo "version=$package_version" >> "$GITHUB_OUTPUT"
```

- 版本在 `dynamic` 里时, 改为读取构建产物 metadata: `python -c 'import importlib.metadata as m; print(m.version("PROJECT"))'`, 并确认它与 tag 对齐.
- 库分发的版本必须是 PyPI 接受的稳定版本号, 不要用 `+<hash>` 本地版本段表达开发状态.
- 不要为了统一版本号在构建脚本里改写 `pyproject.toml`.

## 版本注入与运行时显示

复制 [assets/python/_build_version.py](assets/python/_build_version.py) 到项目源码包内 (例如 `src/<package>/_build_version.py`). 发行构建时由 `scripts/dist.sh` 在同目录生成 `_generated_version.py`:

```python
BUILD_VERSION = "v1.2.3"
```

- 生成文件必须加入 `.gitignore`; 日常开发构建没有它, `_build_version.py` 回落到 `dev-build`.
- 版本号在构建期写入源码再冻结进产物, 这样运行时读到的与产物一致; 不要改成运行时读环境变量.
- 库分发的包不要注入构建版本号, 包版本以 `pyproject.toml` 或生成 metadata 为准.

## 依赖与构建缓存

```yaml
- name: 准备 Python
  uses: actions/setup-python@v7
  with:
    python-version-file: .python-version

- name: 准备 uv
  uses: astral-sh/setup-uv@v10
  with:
    enable-cache: true
```

- 用 uv 管理依赖时优先 `astral-sh/setup-uv` 的 `enable-cache`, 不要再用 `actions/setup-python` 的 `cache` 缓存同一份内容.
- Python 小版本要固定 (`python-version-file` 或 `.python-version`), 不要在 workflow 里写 `3.x`.
- 冻结安装: `uv sync --frozen`, 或 `pip install -r requirements.txt --require-hashes` 之类的等价做法.

## 构建与测试命令

```shell
uv sync --frozen
uv run python -m pytest
uv run ruff check .
uv build
```

- 用 `uv run python -m <tool>` 而不是直接调用工具名, 保证走项目环境.
- 格式检查只报告 (`ruff format --check`), 不要自动改写.
- 库分发的正式构建命令是 `uv build` 或项目既有的构建入口, 产出 wheel 与 sdist.

## 平台目标与 runner

| 平台 | 架构 | runner 标签 | 产物 |
| --- | --- | --- | --- |
| Linux | x86_64 | `ubuntu-24.04` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `.tar.gz` |
| macOS | x86_64 | `macos-15-intel` | `.tar.gz` |
| macOS | aarch64 | `macos-15` | `.tar.gz` |
| Windows | x86_64 | `windows-2025` | `.zip` |
| Windows | aarch64 | `windows-11-arm` | `.zip` |

- PyInstaller 与 Nuitka 不做跨平台编译, 每个平台都要原生 runner.
- wheel 的平台标签与 manylinux 兼容性属于打包工具范围, 用 cibuildwheel 这类工具处理, 不要手写平台 tag.
- 纯 Python 库不需要这张矩阵, 按项目测试需求覆盖平台即可.

## 归档与打包

复制 [assets/python/dist.sh](assets/python/dist.sh) 到 `scripts/dist.sh`, 再复制 [assets/python/entry.py](assets/python/entry.py) 到 `scripts/entry.py` (把里面的包名占位符换掉), 同时复制 [../archive.sh](../archive.sh) 与 [../build-version.sh](../build-version.sh); Windows 侧复制 [assets/python/dist.ps1](assets/python/dist.ps1), [../archive.ps1](../archive.ps1), [../build-version.ps1](../build-version.ps1).

- 只改顶部常量: `PROJECT_NAME`, `PACKAGE_DIR`, `ENTRY`, `PACKAGE_PATH`, `BINARY_NAME`, `SMOKE_ARGS`.
- `ENTRY` 必须指向绝对导入的启动脚本 (`scripts/entry.py`), 不能指向包内的 `__main__.py`: 后者由 `python -m` 执行时相对导入成立, 被 PyInstaller 当作顶层 `__main__` 执行时必然报 `ImportError: attempted relative import with no known parent package`. 已经实测踩过这一次.
- `PACKAGE_PATH` 是包所在的那一层目录 (通常 `src`), 交给 PyInstaller 的 `--paths` 解析绝对导入.
- `BUILD_MODE=pyinstaller` 是生产推荐路径, 需要环境中已安装 PyInstaller; `BUILD_MODE=zipapp` 只用标准库, 但仅适用于 Unix, 适合快速验证与内部工具, 它需要 `ZIPAPP_SOURCE` (包含包目录的那一层) 与 `ZIPAPP_MAIN` (形如 `<包名>.__main__:main`).
- `justfile` 的 `dist` 与 Go 模块给出的形状一致, 只把构建命令换成打包命令.
- 归档内容只放可执行产物, 不要打包整个虚拟环境.

## 生态包发布

- 库分发沿用项目已有的 PyPI 发布入口 (例如 `uv publish` 或 `twine upload`), 不要在 GitHub release job 里内联一套新的发布实现.
- 发布凭据优先用 PyPI 的受信发布 (OIDC), 需要 token 时只放在受限的 publish job.
- 包版本与 tag 严格对齐; 不要把构建版本号写进 `pyproject.toml` 的 `version`.
- GitHub Release 对库分发只出 notes, 不额外上传 wheel 或 sdist.

## 第三方工具分工

| 工具 | 可以承担 | 必须让给本 skill 的部分 |
| --- | --- | --- |
| cibuildwheel | manylinux 与多平台 wheel 构建 | release notes 与 tag 治理 |
| maturin | Rust 扩展模块的 wheel 构建与发布 | 同上 |
| hatch-vcs / setuptools-scm | 由 tag 推导包版本 | tag 本身的创建与校验 |

自动推导版本的工具与人工 notes 可以共存, 但只允许一个版本来源, 不要既写静态 `version` 又启用动态推导.

## 已知坑

- `[project].version` 与 `dynamic` 同时存在会直接报错, 迁移时先确认唯一来源.
- PyInstaller 的入口脚本不能是包内的 `__main__.py`, 相对导入会失败; zipapp 模式则相反, 它按包成员执行, `ZIPAPP_MAIN` 要写成 `<包名>.__main__:main`.
- 打包脚本要加 `--paths <包所在目录>`, 否则冻结时找不到包, 产物启动就报 `ModuleNotFoundError`.
- PyInstaller 对最新的 Python 小版本支持常常滞后, 升级解释器前先确认打包工具是否支持.
- `tomllib` 需要 Python 3.11 及以上; 更早版本改用 `tomli`.
- zipapp 产物在 Windows 上不可执行, Windows 必须走 PyInstaller.
- 冻结产物的体积与启动时间受收集策略影响, 打包后必须真跑一次冒烟检查, 而不是只看构建成功.
