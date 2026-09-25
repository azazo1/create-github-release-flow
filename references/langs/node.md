# Node.js / TypeScript 语言模块

按 SKILL.md 的分派表读取本模块. 这里只写 Node 与 TypeScript 的落地方式; 流程, release notes 治理, tag 与 release 规则见 SKILL.md, 语言无关的 YAML 骨架见 [workflow-patterns.md](../workflow-patterns.md).

## 分发形态判定

| 形态 | 判定依据 | 套用规则 |
| --- | --- | --- |
| 二进制/应用 | `package.json` 有 `bin` 字段, 或项目产出单文件可执行产物 | 运行时版本号显示, 跨平台归档矩阵, SHA256SUMS |
| 库 | 通过 `main` / `exports` 导入, 用户从 npm 获取 | notes-only release, 不打包二进制 |
| 混合 | 同一个包既导出 API 又提供 CLI | 按用户获取方式分别处理; npm 包版本与二进制版本都对齐同一个 tag |

`private: true` 的包只用于内部构建, 不要当成库分发处理.

## 版本来源与 tag 校验

包版本在 `package.json` 的 `version`. 用结构化入口读取, 不要手写正则:

```yaml
- name: 校验 tag 与包版本
  id: release_version
  if: steps.release_context.outputs.is_release == 'true'
  env:
    TAG_NAME: ${{ steps.release_context.outputs.tag_name }}
  shell: bash
  run: |
    set -euo pipefail
    package_version="$(node -p "require('./package.json').version")"
    expected_tag="v$package_version"

    if [[ "$TAG_NAME" != "$expected_tag" ]]; then
      echo "tag $TAG_NAME 与包版本 $package_version 不一致" >&2
      exit 1
    fi

    echo "version=$package_version" >> "$GITHUB_OUTPUT"
```

- workspaces 或 monorepo 里对每个要发布的包各读一次 `package.json`, 全部与 tag 对齐.
- 库分发的包版本必须是稳定 SemVer, 不要把 commit 短 hash 写进 `version`.
- 不要为了统一版本号在构建脚本里改写 `package.json`; 版本由发布准备阶段的提交决定.

## 版本注入与运行时显示

复制 [assets/node/version.ts](assets/node/version.ts) 到项目 `src/version.ts`, 由发行构建在打包期注入:

```shell
bun build src/cli.ts --compile \
  --outfile dist/stage/nodeapp \
  --define "BUILD_VERSION=\"v1.2.3\""
```

```shell
esbuild src/cli.ts --bundle --platform=node \
  --outfile dist/stage/nodeapp \
  --define:BUILD_VERSION="\"v1.2.3\""
```

- 未打包的日常开发构建回落到 `dev-build`, `typeof` 对未声明标识符是安全的.
- 不要在运行时读 `process.env.PROJECT_BUILD_VERSION` 当作发布版本: 那会让产物依赖运行环境的变量.
- 库分发的包不要注入构建版本号, 包版本以 `package.json` 为准.

## 依赖与构建缓存

```yaml
- name: 准备 Node
  uses: actions/setup-node@v7
  with:
    node-version-file: .node-version
    cache: pnpm
    cache-dependency-path: pnpm-lock.yaml
```

- `cache` 按实际包管理器选 `npm`, `pnpm`, `yarn` 或 `bun`; 使用 bun 时改用 `oven-sh/setup-bun` 并自行确认缓存机制.
- 用 `node-version-file` 或 `.nvmrc` 固定 Node 版本, 不要在 workflow 里散落写死.
- lockfile 与包管理器必须匹配: `package-lock.json` 配 npm, `pnpm-lock.yaml` 配 pnpm, `bun.lock` 配 bun; CI 用冻结安装 (例如 `pnpm install --frozen-lockfile`).

## 构建与测试命令

```shell
pnpm install --frozen-lockfile
pnpm run typecheck      # tsc --noEmit
pnpm run build
pnpm run test
```

- 类型检查与构建分开跑, 便于定位失败原因.
- 格式与 lint 检查在 CI 里只报告, 不要自动改写工作区.
- 单文件产物用 `bun build --compile`, 或 esbuild 打包后自行补 shebang; 不要依赖全局安装的运行时.

## 平台目标与 runner

| 平台 | 架构 | runner 标签 | 产物 |
| --- | --- | --- | --- |
| Linux | x86_64 | `ubuntu-24.04` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `.tar.gz` |
| macOS | x86_64 | `macos-15-intel` | `.tar.gz` |
| macOS | aarch64 | `macos-15` | `.tar.gz` |
| Windows | x86_64 | `windows-2025` | `.zip` |
| Windows | aarch64 | `windows-11-arm` | `.zip` |

- `bun build --compile` 只能产出当前平台的可执行文件, 所以每个平台都要用原生 runner, 不要试图交叉编译.
- 含原生扩展 (`node-gyp`, `napi`) 的项目在跨平台产物上必须各平台分别构建与验证.
- 纯 JS 包分发不需要这张矩阵, 按项目测试需求覆盖平台即可.

## 归档与打包

复制 [assets/node/dist.sh](assets/node/dist.sh) 到 `scripts/dist.sh`, 同时复制 [../archive.sh](../archive.sh) 与 [../build-version.sh](../build-version.sh); Windows 侧复制 [assets/node/dist.ps1](assets/node/dist.ps1), [../archive.ps1](../archive.ps1), [../build-version.ps1](../build-version.ps1).

- 只改顶部常量: `PROJECT_NAME`, `ENTRY`, `BINARY_NAME`, `SMOKE_ARGS`; 需要时用 `BUNDLER` 在 bun 与 esbuild 之间切换.
- Windows 产物必须带 `.exe` 后缀并打成 `zip`, 命名里仍用 `windows-x86_64` 这类 token.
- `justfile` 的 `dist` 与 Go 模块给出的形状一致, 只把构建命令换成打包命令.
- 归档内容只放可执行产物; 不要把 `node_modules` 打进去.

## 生态包发布

- 库分发沿用项目已有的 `npm publish` / `pnpm publish` 流程或 recipe, 不要在 GitHub release job 里内联一套新的发布实现.
- 发布凭据优先用 npm 的 OIDC 受信发布, 需要长期 token 时只放在受限的 publish job, 不要给 release job 额外权限.
- 包版本与 tag 严格对齐; 不要把构建版本号或 commit hash 写进 `package.json` 的 `version`.
- GitHub Release 对库分发只出 notes, 不额外打一份 npm tarball 归档.

## 第三方工具分工

| 工具 | 可以承担 | 必须让给本 skill 的部分 |
| --- | --- | --- |
| changesets | 版本号升级 PR 与包发布编排 | tag annotation 与 release notes 正文 |
| semantic-release | 版本判定与发布流程 | 它自动生成的 changelog 不能当 release notes; tag 与 notes 仍按本 skill 治理 |
| bun / esbuild | 打包与单文件产物 | 产物命名, 数量校验与 SHA256SUMS |

自动生成 changelog 的工具与人工 notes 同时存在时, 必须明确只有 `docs/changelog/VERSION.md` 会进入 Release 正文.

## 已知坑

- 不固定 Node 版本时, 本地与 CI 行为会漂移; 原生扩展尤其明显.
- `bin` 字段指向的文件需要可执行位与 shebang, 打包成单文件产物后不再依赖 `bin`.
- ESM 与 CJS 混用时打包器会改变 `__dirname` 之类行为, 产物必须真跑一次冒烟检查.
- `macos-latest` 现在是 macOS 26 arm64, `ubuntu-latest` 是 x64; 不要用 `*-latest` 推断架构.
- 打包后的可执行文件体积较大, 不要把它同时塞进 npm 包与 GitHub Release, 二者选一.
