# GitHub Release Workflow Patterns

仅在实现对应步骤时读取和改写这些片段. 不要直接复制未替换的占位符.

## 目录

- [Tag 触发](#tag-触发)
- [Job 依赖](#job-依赖)
- [平台与架构](#平台与架构)
- [多行 annotated tag 描述](#多行-annotated-tag-描述)
- [校验和](#校验和)
- [验证 annotated tag](#验证-annotated-tag)

示例中的 action major version 只是结构的一部分. 使用前确认当前稳定版本和项目的 action pinning 策略.

## Tag 触发

```yaml
on:
  push:
    tags:
      - "v*"
      - "[0-9]*"

permissions:
  contents: read

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

收窄 pattern 只能减少无效运行, 不能替代严格的版本校验.

## Job 依赖

```yaml
jobs:
  version:
    # 读取项目 metadata, 校验 tag, 输出 version.

  prepare:
    needs: version
    # 执行项目已有的生成或准备命令, 上传必要输出.

  build:
    needs: [version, prepare]
    strategy:
      fail-fast: false
      matrix:
        include: []

  release:
    needs: [version, build]
    permissions:
      contents: write
```

没有共享生成输入时可以删除 `prepare`, 但必须先在干净 checkout 中确认.

## 平台与架构

在使用前查阅 GitHub hosted runner 官方文档, 不要仅依赖此表. 常见 64 位发布标识如下:

| OS | Architecture | Artifact platform ID |
| --- | --- | --- |
| Linux | x86_64 | `linux-x86_64` |
| Linux | aarch64 | `linux-aarch64` |
| Windows | x86_64 | `windows-x86_64` |
| Windows | aarch64 | `windows-aarch64` |
| macOS | x86_64 | `macos-x86_64` |
| macOS | aarch64 | `macos-aarch64` |

这些 ID 只用于归档命名, 不是实际构建 target. 应从项目工具链确定真正的构建参数. 动态链接的 Linux 产物通常会继承构建 runner 的 glibc 下限. 需要广泛兼容旧发行版时, 明确评估较旧 runner, 静态链接方案或容器化 sysroot, 不要把普通 Linux 产物误称为通用静态二进制.

## 多行 annotated tag 描述

在 release job 中完整 checkout tags:

```yaml
- name: Checkout release tag
  uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Extract tag description
  shell: bash
  run: |
    set -euo pipefail
    tag_ref="refs/tags/$GITHUB_REF_NAME"

    if [[ "$(git cat-file -t "$tag_ref")" == "tag" ]]; then
      git for-each-ref \
        --format='%(contents:subject)%0a%0a%(contents:body)' \
        "$tag_ref" > tag-notes.md
    else
      : > tag-notes.md
    fi
```

`contents:subject` 和 `contents:body` 保留标题及多行正文, 同时不把签名块写进 release notes. Lightweight tag 指向 commit 而不是 tag object, 因此生成空文件.

使用支持 `body_path` 和 GitHub generated notes 的 release action:

```yaml
- name: Create release
  uses: softprops/action-gh-release@v2
  with:
    name: PROJECT v${{ needs.version.outputs.version }}
    body_path: tag-notes.md
    generate_release_notes: true
    fail_on_unmatched_files: true
    files: |
      dist/*.tar.gz
      dist/*.zip
      dist/SHA256SUMS
```

GitHub Releases API 规定, 同时指定 `body` 和 `generate_release_notes` 时, 显式 body 会放在自动生成内容之前.

## 校验和

在 Unix release runner 上汇总已下载的归档:

```yaml
- name: Generate checksums
  shell: bash
  run: |
    set -euo pipefail
    cd dist
    sha256sum PROJECT-* > SHA256SUMS
```

限制 glob 只匹配归档, 避免旧的 `SHA256SUMS` 被递归纳入自身. 确保 release job 从空目录开始.

## 验证 annotated tag

测试样本至少包含:

```text
Release summary

First paragraph.

Second paragraph.
- item one
- item two
```

对提取结果进行内容检查, 不只检查命令退出码.
