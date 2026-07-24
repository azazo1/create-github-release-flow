# GitHub Release Workflow Patterns

仅在实现对应步骤时读取和改写这些片段. 不要直接复制未替换的占位符.

## 目录

- [GitHub Release Workflow Patterns](#github-release-workflow-patterns)
  - [目录](#目录)
  - [触发与并发](#触发与并发)
  - [CI, tag 与手动条件](#ci-tag-与手动条件)
  - [平台与架构](#平台与架构)
  - [Rust 版本校验](#rust-版本校验)
  - [平台产物校验](#平台产物校验)
  - [版本化 release notes](#版本化-release-notes)
  - [Annotated tag 正文](#annotated-tag-正文)
  - [校验和与数量检查](#校验和与数量检查)
  - [创建或更新 release](#创建或更新-release)

示例中的 action major version 和 runner 标签只是结构的一部分. 使用前确认当前稳定版本, runner 可用性和项目的 action pinning 策略.

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
        description: "要发布的已有 tag, 留空时只构建"
        required: false
        type: string

permissions:
  contents: read

concurrency:
  group: ci-${{ inputs.tag != '' && format('refs/tags/{0}', inputs.tag) || github.ref }}
  cancel-in-progress: false
```

收窄 tag pattern 只能减少无效运行, 不能替代严格的版本校验. 手动触发的 `tag` 为空时只运行所选 ref 的构建, 非空时发布该已有 tag.

## CI, tag 与手动条件

先解析统一的 release context, 再让 branch 和 PR 完成矩阵构建, 只让 tag push 或带 tag input 的手动触发执行发布步骤:

```yaml
jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      is_release: ${{ steps.release_context.outputs.is_release }}
      tag_name: ${{ steps.release_context.outputs.tag_name }}
      source_ref: ${{ steps.release_context.outputs.source_ref }}
      version: ${{ steps.release_version.outputs.version }}
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

      - name: 检出发布 tag
        if: steps.release_context.outputs.is_release == 'true'
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.release_context.outputs.source_ref }}

      - name: 校验发布版本
        id: release_version
        if: steps.release_context.outputs.is_release == 'true'
        shell: bash
        run: |
          # 读取项目 metadata, 并与解析后的 tag 名比较.

  build:
    needs: version
    strategy:
      fail-fast: false
      matrix:
        include: []
    steps:
      - name: 检出目标提交
        uses: actions/checkout@v4
        with:
          ref: ${{ needs.version.outputs.source_ref }}

      - name: 构建
        run: PROJECT_BUILD_COMMAND

      - name: 打包发布产物
        if: needs.version.outputs.is_release == 'true'
        run: PROJECT_PACKAGE_COMMAND

      - name: 上传发布产物
        if: needs.version.outputs.is_release == 'true'
        uses: actions/upload-artifact@v4

  release:
    if: needs.version.outputs.is_release == 'true'
    needs: [version, build]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: 检出发布 tag
        uses: actions/checkout@v4
        with:
          ref: ${{ needs.version.outputs.source_ref }}
          fetch-depth: 0
```

没有 tag 时 `version` job 可以成功完成但不产生 version output. 只在 `is_release` 条件的步骤和 job 中消费该 output. Release job 也要用 `source_ref` 检出目标 tag, 不要依赖 workflow dispatch 所在 branch 的默认 checkout.

## 平台与架构

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

GUI 程序不适合通过 `--version` 启动时, 检查文件格式和必要路径.

Unix runner 示例:

```yaml
- name: 校验 Unix 二进制文件
  if: needs.version.outputs.is_release == 'true'
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
  if: needs.version.outputs.is_release == 'true'
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

## 版本化 release notes

将人工说明作为正文主体, 再追加 GitHub generated notes:

```yaml
- name: 生成 release notes
  env:
    GH_TOKEN: ${{ github.token }}
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
    VERSION: ${{ needs.version.outputs.version }}
  shell: bash
  run: |
    set -euo pipefail
    manual_notes="docs/release-notes/$VERSION.md"
    base_tag_file="docs/release-notes/$VERSION-base.txt"

    if [[ ! -s "$manual_notes" ]]; then
      echo "缺少 release notes: $manual_notes" >&2
      exit 1
    fi

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
      printf '\n\n' >> release-notes.md
      cat generated-notes.md >> release-notes.md
    fi
```

Release job 需要按 `source_ref` 完整 checkout tags. `git rev-parse HEAD` 保证手动发布使用目标 tag 的 commit, 而不是 workflow dispatch 所在 branch 的 `github.sha`. Base tag 文件只处理自动推导不正确的版本, 不要为每个版本都创建.

## Annotated tag 正文

仅在仓库明确使用 annotated tag 正文作为人工 release notes 来源时使用本节. `actions/checkout` 可能把本地 `refs/tags/TAG` 写成 peeled commit, `fetch-depth: 0` 不能保证该 ref 仍指向 tag object.

检出发布 tag 后, 使用解析得到的 `tag_name` 精确 refetch 远端 tag ref, 再验证对象类型并提取正文:

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

- name: 提取 annotated tag 正文
  env:
    TAG_NAME: ${{ needs.version.outputs.tag_name }}
  shell: bash
  run: |
    set -euo pipefail
    tag_ref="refs/tags/$TAG_NAME"
    tag_type="$(git cat-file -t "$tag_ref")"

    if [[ "$tag_type" != "tag" ]]; then
      echo "发布 tag 必须是带有手写说明的 annotated tag: $TAG_NAME" >&2
      exit 1
    fi

    git for-each-ref \
      --format='%(contents:subject)%0a%0a%(contents:body)' \
      "$tag_ref" > release-notes.md

    if ! grep -q '[^[:space:]]' release-notes.md; then
      echo "发布 tag 的手写说明不能为空: $TAG_NAME" >&2
      exit 1
    fi
```

手动发布必须使用 release context 输出的 `tag_name`. `github.ref_name` 在 `workflow_dispatch` 中通常是触发 workflow 的 branch, 不能用来定位待发布 tag. 如果还要追加 generated notes, 将其追加到 `release-notes.md`, 不要覆盖已经提取的正文.

## 校验和与数量检查

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

重跑时更新已存在的 release 并覆盖产物:

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
