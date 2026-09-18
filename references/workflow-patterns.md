# GitHub Release Workflow Patterns

仅在实现对应步骤时读取和改写这些片段. 不要直接复制未替换的占位符.

## 目录

- [GitHub Release Workflow Patterns](#github-release-workflow-patterns)
  - [目录](#目录)
  - [触发与并发](#触发与并发)
  - [CI, tag 与手动条件](#ci-tag-与手动条件)
  - [依赖与构建缓存](#依赖与构建缓存)
  - [平台与架构](#平台与架构)
  - [Rust 版本校验](#rust-版本校验)
  - [平台产物校验](#平台产物校验)
  - [发布说明与 annotated tag](#发布说明与-annotated-tag)
  - [校验和与数量检查](#校验和与数量检查)
  - [创建或更新 release](#创建或更新-release)
  - [库分发的 notes-only release](#库分发的-notes-only-release)

示例中的 action major version 和 runner 标签只是结构的一部分. 使用前确认当前稳定版本, runner 可用性和项目的 action pinning 策略. 示例统一使用 node24 runtime 的 action major, 因为 node20 runtime 的旧 major 会在 runner 移除 node20 后直接失败: checkout v5+, upload-artifact v6+, download-artifact v7+, cache v5+, setup-node v5+, setup-python v6+. 这些 major 要求 runner 不低于 2.327.1, 自建 runner 需要先升级 runner 版本.

## 触发与并发

普通 CI, tag 发布和手动触发共用 workflow 时, 保留 branch, PR, tag 和 `workflow_dispatch` 触发:

```yaml
on:
  push:
    branches:
      - "**"
    tags:
      - "v*"
  pull_request:
  workflow_dispatch:
    inputs:
      tag:
        description: "要发布的已有 tag, 留空时不创建 release"
        required: false
        type: string

permissions:
  contents: read

concurrency:
  group: ci-${{ inputs.tag != '' && format('refs/tags/{0}', inputs.tag) || github.ref }}
  cancel-in-progress: false
```

收窄 tag pattern 只能减少无效运行, 不能替代严格的版本校验. 手动触发是否发布由 `tag` 是否为空决定.

## CI, tag 与手动条件

先解析统一的 release context, 再让 branch, PR, tag 和手动触发都完成矩阵检查. 二进制/应用还要打包并上传 artifact. 只让 tag push 或带 tag input 的手动触发执行发布步骤:

```yaml
jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      is_release: ${{ steps.release_context.outputs.is_release }}
      tag_name: ${{ steps.release_context.outputs.tag_name }}
      source_ref: ${{ steps.release_context.outputs.source_ref }}
      version: ${{ steps.release_version.outputs.version }}
      build_version: ${{ steps.build_version.outputs.build_version }}
    steps:
      - name: 解析发布上下文
        id: release_context
        env:
          EVENT_NAME: ${{ github.event_name }}
          CURRENT_REF: ${{ github.ref }}
          CURRENT_REF_NAME: ${{ github.ref_name }}
          CURRENT_SHA: ${{ github.sha }}
          DISPATCH_TAG: ${{ inputs.tag }}
        shell: bash
        run: |
          set -euo pipefail
          is_release=false
          tag_name=""
          source_ref="$CURRENT_SHA"

          if [[ "$EVENT_NAME" == "push" && "$CURRENT_REF" == refs/tags/* ]]; then
            is_release=true
            tag_name="$CURRENT_REF_NAME"
            source_ref="$CURRENT_REF"
          elif [[ "$EVENT_NAME" == "workflow_dispatch" && -n "$DISPATCH_TAG" ]]; then
            git check-ref-format "refs/tags/$DISPATCH_TAG"
            is_release=true
            tag_name="$DISPATCH_TAG"
            source_ref="refs/tags/$DISPATCH_TAG"
          fi

          echo "is_release=$is_release" >> "$GITHUB_OUTPUT"
          echo "tag_name=$tag_name" >> "$GITHUB_OUTPUT"
          echo "source_ref=$source_ref" >> "$GITHUB_OUTPUT"

      - name: 检出目标提交
        uses: actions/checkout@v7
        with:
          ref: ${{ steps.release_context.outputs.source_ref }}
          fetch-depth: 0
          fetch-tags: true

      - name: 校验发布版本
        id: release_version
        if: steps.release_context.outputs.is_release == 'true'
        shell: bash
        run: |
          # 读取项目 metadata, 并与解析后的 tag 名比较.

      - name: 解析构建版本
        id: build_version
        env:
          IS_RELEASE: ${{ steps.release_context.outputs.is_release }}
          RELEASE_VERSION: ${{ steps.release_version.outputs.version }}
        shell: bash
        run: |
          set -euo pipefail
          if [[ "$IS_RELEASE" == "true" ]]; then
            echo "build_version=$RELEASE_VERSION" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          echo "build_version=$(bash scripts/build-version.sh)" >> "$GITHUB_OUTPUT"

  build:
    needs: version
    strategy:
      fail-fast: false
      matrix:
        include: []
    steps:
      - name: 检出目标提交
        uses: actions/checkout@v7
        with:
          ref: ${{ needs.version.outputs.source_ref }}
          fetch-depth: 0
          fetch-tags: true

      - name: 构建
        env:
          PROJECT_BUILD_VERSION: v${{ needs.version.outputs.build_version }}
        run: PROJECT_BUILD_COMMAND

      - name: 打包构建产物
        run: PROJECT_PACKAGE_COMMAND

      - name: 上传构建产物
        uses: actions/upload-artifact@v7
        with:
          name: PROJECT-${{ needs.version.outputs.build_version }}-${{ matrix.platform }}-${{ matrix.arch }}
          path: EXPECTED_PACKAGE_PATH
          if-no-files-found: error
          retention-days: 14

  release:
    if: needs.version.outputs.is_release == 'true'
    needs: [version, build]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: 检出发布 tag
        uses: actions/checkout@v7
        with:
          ref: ${{ needs.version.outputs.source_ref }}
          fetch-depth: 0
```

没有 tag 时 `version` job 可以成功完成但不产生 version output. 只在 `is_release` 条件的步骤和 job 中消费该 output. 二进制/应用的打包和 artifact 上传不要再加 `is_release` 或 `workflow_dispatch` 条件, 非 release 产物用 `build_version` 命名, 平台相关产物的 Actions artifact 名也要带上这个版本号以及 platform 和 arch, 平台无关的托管运行时产物 (如 .NET dll, Java jar) 按其自身规则命名, 不加 platform 和 arch. 库分发省略打包, artifact 上传和 SHA256SUMS 步骤, 矩阵按测试需求覆盖. Release job 也要用 `source_ref` 检出目标 tag, 不要依赖 workflow dispatch 所在 branch 的默认 checkout.

## 依赖与构建缓存

构建或测试 job 应配置依赖与构建缓存, 但缓存只用于加速, 不能作为发布正确性来源. 优先使用该语言或工具链已验证的专用缓存机制, 没有可用专用机制时才回退到通用缓存.

常用优先方案:

| 工具链/语言 | 优先缓存机制 |
| --- | --- |
| Rust | `Swatinem/rust-cache` |
| Node.js | `actions/setup-node` 的 `cache` 输入 |
| Python | `actions/setup-python` 的 `cache` 输入 |
| Go | `actions/setup-go` 的 `cache` 输入 |
| uv | `astral-sh/setup-uv` 的 `enable-cache` 输入 |

使用前确认对应 action 的当前稳定版本, 项目 lockfile 和仓库 pinning 策略. 专用缓存不可用或不匹配项目结构时, 使用通用缓存:

```yaml
- name: 恢复依赖与构建缓存
  uses: actions/cache@v6
  with:
    path: |
      PROJECT_DEPENDENCY_CACHE_PATH
      PROJECT_BUILD_CACHE_PATH
    key: ${{ runner.os }}-${{ matrix.arch }}-${{ hashFiles('PROJECT_LOCKFILE') }}
    restore-keys: |
      ${{ runner.os }}-${{ matrix.arch }}-
```

`actions/cache@v6` 的 path 要覆盖包管理器缓存和构建缓存, 不缓存发布产物; key 包含 runner 系统, 矩阵架构和 lockfile hash; restore-keys 用于 key 变化时的回退. 缓存 miss 或恢复失败不能导致构建失败, 干净环境必须能完整构建. 不同平台和架构的缓存必须隔离, 不要对同一路径同时配置专用缓存和通用缓存. 没有 lockfile 时使用稳定的依赖清单 hash 或跳过缓存, 不要只按分支名生成 key.

## 平台与架构

仅二进制/应用分发需要此归档矩阵. 库分发按项目现有测试需求覆盖平台, 不要为了发布归档去扩矩阵.

在使用前查阅 GitHub hosted runner 官方文档, 不要仅依赖此表. 常见原生 64 位目标如下:

| 平台 | 架构 | Rust target | 常见归档 |
| --- | --- | --- | --- |
| Linux | x86_64 | `x86_64-unknown-linux-gnu` | `.tar.gz` |
| Linux | aarch64 | `aarch64-unknown-linux-gnu` | `.tar.gz` |
| Linux | x86_64 | `x86_64-unknown-linux-musl` | `.tar.gz` |
| Linux | aarch64 | `aarch64-unknown-linux-musl` | `.tar.gz` |
| Windows | x86_64 | `x86_64-pc-windows-msvc` | `.zip` |
| Windows | aarch64 | `aarch64-pc-windows-msvc` | `.zip` |
| macOS | x86_64 | `x86_64-apple-darwin` | CLI 使用 `.tar.gz`, 桌面应用使用 `.dmg` |
| macOS | aarch64 | `aarch64-apple-darwin` | CLI 使用 `.tar.gz`, 桌面应用使用 `.dmg` |

动态链接的 Linux 产物通常会继承构建 runner 的 glibc 下限. 需要兼容旧发行版时, 明确评估较旧 runner, 静态链接方案或容器化 sysroot, 不要把普通 GNU 动态链接产物描述为通用静态二进制.

## Rust 版本校验

通过结构化 metadata 获取包版本:

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
      cargo metadata --locked --no-deps --format-version 1 |
        jq -er '.packages[] | select(.name == "PROJECT") | .version'
    )"
    expected_tag="v$package_version"

    if [[ "$TAG_NAME" != "$expected_tag" ]]; then
      echo "tag $TAG_NAME 与包版本 $package_version 不一致" >&2
      exit 1
    fi

    echo "version=$package_version" >> "$GITHUB_OUTPUT"
```

项目不是 Rust workspace, 或版本不在包 metadata 中时, 使用该生态的结构化 metadata 入口替换此步骤.

## 平台产物校验

仅二进制/应用分发需要本节. GUI 程序不适合通过 `--version` 启动时, 检查文件格式和必要路径.

Unix runner 示例:

```yaml
- name: 校验 Unix 二进制文件
  shell: bash
  run: |
    set -euo pipefail
    binary="target/TARGET/release/PROJECT"
    test -x "$binary"
    file "$binary" | grep -q 'EXPECTED_FORMAT'
```

Windows runner 示例:

```yaml
- name: 校验 Windows 二进制文件
  shell: pwsh
  run: |
    $binary = "target/TARGET/release/PROJECT.exe"
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
      throw "缺少 Windows 二进制文件: $binary"
    }
    $header = [System.IO.File]::ReadAllBytes($binary)
    if ($header.Length -lt 2 -or $header[0] -ne 0x4d -or $header[1] -ne 0x5a) {
      throw "PE 文件头无效: $binary"
    }
```

Linux 的 `EXPECTED_FORMAT` 使用 `ELF`, macOS 使用 `Mach-O`. 还需要检查应用包结构时, 在平台打包脚本返回后追加路径断言.

桌面应用产出的 macOS dmg 必须包含指向 `/Applications` 的符号链接, 例如 `Applications` -> `/Applications`, 让用户能直接把 `.app` 拖进该目录完成安装. dmg 需同时包含应用的 `.app` 包. 下面是在打包脚本返回后, 挂载 dmg 校验这两个路径的示例:

```yaml
- name: 校验 dmg 包含 Applications 替身与应用包
  shell: bash
  run: |
    set -euo pipefail
    dmg="release-artifacts/PROJECT.dmg"
    mount_point="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg"
    trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true' EXIT

    test -L "$mount_point/Applications"
    test -d "$mount_point/PROJECT.app"
```

`readlink "$mount_point/Applications"` 应解析到 `/Applications`. 如果项目打包脚本使用别名替身而不是符号链接 (例如 `ln -s` 之外的 alias 方式), 调整对应断言, 但必须确保该目录确实指向 `/Applications`.

## 发布说明与 annotated tag

将 `docs/changelog/VERSION.md` 作为人工发布说明的唯一来源. 先提交版本号和说明文件, 再让 annotated tag 指向该 commit. 使用说明文件直接创建 tag:

```shell
git tag -a "v0.1.0" --cleanup=verbatim \
  -F "docs/changelog/0.1.0.md"
```

必须使用 `--cleanup=verbatim`, 否则 Git 默认的 `strip` 模式会删除 Markdown 中以 `#` 开头的标题. 不要再用 `-m` 维护另一份 tag 正文. Tag 已存在或已推送时不要直接覆盖.

Release job 按 `source_ref` 完整 checkout tags 后, 精确 refetch 远端 tag object, 提取 annotation, 并与版本化说明文件比较:

```yaml
- name: 重新获取 annotated tag object
  env:
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
  shell: bash
  run: |
    set -euo pipefail
    git check-ref-format "refs/tags/$TAG_NAME"
    git fetch --force origin \
      "refs/tags/$TAG_NAME:refs/tags/$TAG_NAME"

- name: 校验 tag annotation
  env:
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
    VERSION: ${{ needs.version.outputs.version }}
  shell: bash
  run: |
    set -euo pipefail
    tag_ref="refs/tags/$TAG_NAME"
    manual_notes="docs/changelog/$VERSION.md"

    if [[ ! -s "$manual_notes" ]]; then
      echo "缺少 release notes: $manual_notes" >&2
      exit 1
    fi

    tag_type="$(git cat-file -t "$tag_ref")"
    if [[ "$tag_type" != "tag" ]]; then
      echo "发布 tag 必须是 annotated tag: $TAG_NAME" >&2
      exit 1
    fi

    git cat-file tag "$tag_ref" | sed '1,/^$/d' > tag-notes.md
    if ! grep -q '[^[:space:]]' tag-notes.md; then
      echo "发布 tag 的 annotation 不能为空: $TAG_NAME" >&2
      exit 1
    fi

    if ! cmp -s "$manual_notes" tag-notes.md; then
      echo "发布 tag 的 annotation 与 $manual_notes 不一致" >&2
      diff -u "$manual_notes" tag-notes.md || true
      exit 1
    fi

- name: 生成 release notes
  env:
    GH_TOKEN: ${{ github.token }}
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
    VERSION: ${{ needs.version.outputs.version }}
  shell: bash
  run: |
    set -euo pipefail
    manual_notes="docs/changelog/$VERSION.md"
    base_tag_file="docs/changelog/$VERSION-base.txt"
    api_args=(
      --method POST
      "repos/$GITHUB_REPOSITORY/releases/generate-notes"
      -f "tag_name=$TAG_NAME"
    )

    target_sha="$(git rev-parse HEAD)"
    api_args+=(-f "target_commitish=$target_sha")

    if [[ -s "$base_tag_file" ]]; then
      base_tag="$(<"$base_tag_file")"
      git check-ref-format "refs/tags/$base_tag"
      api_args+=(-f "previous_tag_name=$base_tag")
    fi

    gh api "${api_args[@]}" --jq '.body' > generated-notes.md
    cp "$manual_notes" release-notes.md

    if [[ -s generated-notes.md ]]; then
      printf '\n---\n\n' >> release-notes.md
      cat generated-notes.md >> release-notes.md
    fi
```

自动生成内容用 `---` 与人工正文分隔, 避免 PR 列表直接贴在人工正文后面.

`git cat-file tag` 保留原始 annotation, 去除 tag object header 后可以与 Markdown 文件做字节比较. 不要用 `for-each-ref --format='%(contents)'` 做这个比较, 因为它会额外附加换行. 手动发布必须使用 release context 输出的 `tag_name`, `github.ref_name` 通常只是触发 workflow 的 branch. Base tag 文件只处理自动推导不正确的版本, 不要为每个版本都创建.

## 校验和与数量检查

仅二进制/应用分发需要本节. 库分发的 notes-only release 跳过归档计数和 SHA256SUMS.

从空目录汇总归档, 并显式校验矩阵产物数量:

```yaml
- name: 生成校验和
  shell: bash
  run: |
    set -euo pipefail
    shopt -s nullglob
    cd release-artifacts
    archives=(PROJECT-*.tar.gz PROJECT-*.zip PROJECT-*.dmg)

    if (( ${#archives[@]} != EXPECTED_ARCHIVE_COUNT )); then
      echo "预期 EXPECTED_ARCHIVE_COUNT 个归档, 实际找到 ${#archives[@]} 个" >&2
      exit 1
    fi

    sha256sum "${archives[@]}" > SHA256SUMS
```

限制 glob 只匹配预期归档, 避免 `SHA256SUMS` 被递归纳入自身. 上传前再校验 assets 总数为归档数加 1.

## 创建或更新 release

仅二进制/应用分发需要上传归档. 重跑时更新已存在的 release 并覆盖产物:

```yaml
- name: 创建或更新 GitHub Release
  env:
    GH_TOKEN: ${{ github.token }}
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
    VERSION: ${{ needs.version.outputs.version }}
  shell: bash
  run: |
    set -euo pipefail
    shopt -s nullglob
    assets=(
      release-artifacts/PROJECT-*.tar.gz
      release-artifacts/PROJECT-*.zip
      release-artifacts/PROJECT-*.dmg
      release-artifacts/SHA256SUMS
    )

    if (( ${#assets[@]} != EXPECTED_ASSET_COUNT )); then
      echo "预期 EXPECTED_ASSET_COUNT 个发布文件, 实际找到 ${#assets[@]} 个" >&2
      exit 1
    fi

    prerelease_args=()
    if [[ "$VERSION" == *-* ]]; then
      prerelease_args+=(--prerelease)
    fi

    if gh release view "$TAG_NAME" >/dev/null 2>&1; then
      gh release edit "$TAG_NAME" \
        --verify-tag \
        --title "PROJECT v$VERSION" \
        --notes-file release-notes.md \
        "${prerelease_args[@]}"
      gh release upload "$TAG_NAME" "${assets[@]}" --clobber
    else
      gh release create "$TAG_NAME" "${assets[@]}" \
        --verify-tag \
        --title "PROJECT v$VERSION" \
        --notes-file release-notes.md \
        "${prerelease_args[@]}"
    fi
```

在执行前将 `EXPECTED_ARCHIVE_COUNT` 和 `EXPECTED_ASSET_COUNT` 替换为矩阵对应的确定值, 不要保留未展开的占位符.

## 库分发的 notes-only release

库分发不上传归档或 SHA256SUMS. `gh release create` 不带资产; 已存在时只用 `gh release edit` 更新标题和正文:

```yaml
- name: 创建或更新 GitHub Release
  env:
    GH_TOKEN: ${{ github.token }}
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
    VERSION: ${{ needs.version.outputs.version }}
  shell: bash
  run: |
    set -euo pipefail

    prerelease_args=()
    if [[ "$VERSION" == *-* ]]; then
      prerelease_args+=(--prerelease)
    fi

    if gh release view "$TAG_NAME" >/dev/null 2>&1; then
      gh release edit "$TAG_NAME" \
        --verify-tag \
        --title "PROJECT v$VERSION" \
        --notes-file release-notes.md \
        "${prerelease_args[@]}"
    else
      gh release create "$TAG_NAME" \
        --verify-tag \
        --title "PROJECT v$VERSION" \
        --notes-file release-notes.md \
        "${prerelease_args[@]}"
    fi
```

不要为了形式上传空的 `SHA256SUMS`. 版本校验, annotated tag 比较和 generated notes 仍按前文步骤执行.
