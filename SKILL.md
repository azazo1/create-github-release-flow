---
name: create-github-release-flow
description: 创建或修改 GitHub Actions 跨平台 CI 和 tag 发布流程. 适用于仓库需要版本校验, 手动发布, release notes, 多平台产物打包或 GitHub Release 自动发布时. 打 tag push 必读.
---

# 创建 GitHub Release 流

## 目标

先确认项目现有的 CI, 构建, 打包和版本规则, 再实现以下流程:

```text
release preparation -> write VERSION.md -> commit -> annotated tag from VERSION.md -> push
branch/PR -> build matrix
tag -> validate version -> build matrix -> validate/package -> notes/checksums -> create/update release
manual branch -> build matrix
manual tag -> validate version -> build matrix -> validate/package -> notes/checksums -> create/update release
```

默认让普通 CI, tag 发布和手动触发复用同一套构建矩阵. 普通 branch 和 PR 只构建. Tag push 或显式指定已有 tag 的手动触发执行版本校验和发布. 如果仓库已有独立发布 workflow, 可以保留分离结构, 但不要复制构建逻辑.

构建, 校验或产物完整性检查失败时不得创建公开 release.

## 工作流程

### 1. 确认项目规则

阅读项目说明, 现有 CI, task runner 和打包脚本, 确认:

- tag 格式和版本来源.
- 正式构建命令与 lockfile.
- branch, PR 和 tag 当前执行的 job.
- 二进制, 应用包和归档的输出路径.
- 各平台的编译 target, runner 和运行时兼容要求.
- release notes, changelog 和历史 release 的维护方式.
- CLI, TUI, GUI 等展示版本号的交互位置及其版本信息的生成方式.

CLI, TUI, GUI 等可能展示版本号的交互位置 (如 `--version`, About 对话框) 必须显示当前构建版本并标注构建 commit:

- 构建 commit 恰好是某个版本 tag 时, 直接显示该 tag, 例如 `v1.2.3`.
- 构建处于非 tag commit 时, 在最近一个版本 tag 后追加 `-` 和 7 位短 hash, 例如 `v1.2.3-a1b2c3d`.
- HEAD 工作区有未提交改动时, 改用 `^` 分隔, 例如 `v1.2.3^a1b2c3d`.
- 基础版本号样式跟随最近一个版本 tag, 不要固定假设带 `v` 前缀或三段式 SemVer.

> 版本号显示必须自动生成, 而不是手动编辑写死.

优先调用项目已有的 task runner 或打包脚本. 平台专用打包包含应用目录, 图标, metadata 或签名准备时, 将逻辑放在项目脚本中, 不要把完整实现内联到 workflow.

在项目需要新增 Just recipe 时, 统一提供 `just dist`. 该 recipe 根据当前运行平台执行相应构建, 必须不接受任何参数, 不要声明 `*args` 或位置参数, 也不要新增 `package-macos`, `package-windows` 等按平台命名的 recipe.

例如, 为同一 `dist` recipe 添加互斥的平台属性:

```justfile
# 根据当前平台生成发布产物.
[windows]
dist:
    powershell -NoProfile -File scripts/dist-windows.ps1

[macos]
dist:
    ./scripts/dist-macos.sh

[linux]
dist:
    ./scripts/dist-linux.sh
```

实现具体 YAML 片段时按需读取 [workflow-patterns.md](references/workflow-patterns.md), 不要一次性复制所有示例.

### 2. 组织 CI, tag 与手动触发

根据项目惯例匹配 `v1.2.3` 或 `1.2.3` 等 tag. Tag pattern 只负责减少无效运行, workflow 内仍要严格校验版本.

如果项目文件中保存版本号, 使用结构化 metadata 命令读取, 规范化 tag 后严格比较. Rust 项目优先使用 `cargo metadata --locked --no-deps --format-version 1`, 不要用文本正则读取 `Cargo.toml`. 如果 tag 是唯一版本来源, 不要额外维护第二份版本状态.

添加 `workflow_dispatch` 和可选字符串 input `tag`. 空值表示对用户在 GitHub UI 或 API 中选择的 ref 运行构建并上传 Actions artifact, 但不创建 release. 非空值表示发布该已有 tag. 不要让手动发布隐式使用触发 workflow 的 branch commit.

在 `version` job 的第一个步骤统一解析并输出:

- `is_release`: tag push 或手动提供 tag 时为 `true`.
- `tag_name`: tag push 的 ref name 或手动输入的 tag.
- `source_ref`: tag 发布时为 `refs/tags/TAG`, 其他情况为当前事件的 `github.sha`.
- `version`: 仅在 `is_release` 为 `true` 且版本校验成功后输出.

手动 tag 先用 `git check-ref-format "refs/tags/$TAG_NAME"` 校验格式, 再检出完整 tag. Tag 不存在时必须在构建开始前失败.

当普通 CI 和发布共用 workflow 时:

- `version` job 保持可被构建 job 依赖, 但版本校验步骤只在 `is_release` 为 `true` 时执行.
- 构建 job 使用 `source_ref` 检出代码, 确保手动发布构建的是目标 tag.
- 构建矩阵在 branch, PR, tag 和手动触发上执行.
- 产物校验, 打包和 artifact 上传步骤在 `is_release` 为 `true` 或事件为 `workflow_dispatch` 时执行.
- release job 只在 `is_release` 为 `true` 时执行, 并依赖版本校验和全部矩阵构建.

为每个 ref 或手动输入 tag 设置 concurrency group, 并使用 `cancel-in-progress: false`, 防止同一 tag 的 push 和手动发布并发修改 release.

### 3. 构建, 校验并打包

默认覆盖以下构建矩阵:

| 平台 | 架构 | 常见归档 |
| --- | --- | --- |
| Linux | `x86_64` | `.tar.gz` |
| Linux | `aarch64` | `.tar.gz` |
| Windows | `x86_64` | `.zip` |
| Windows | `aarch64` | `.zip` |
| macOS | `x86_64` | CLI 使用 `.tar.gz`, 桌面应用使用 `.dmg` |
| macOS | `aarch64` | CLI 使用 `.tar.gz`, 桌面应用使用 `.dmg` |

在实现时查阅 GitHub 官方 runner 文档, 确认当前可用的 runner 标签和仓库资格. 优先使用对应系统和架构的原生 runner. 无法原生构建时使用项目成熟的交叉编译工具链, 并明确 linker, sysroot 和系统库要求.

> 注: 不要使用已经退役的 runner, 比如 macos-13-intel 等.

每个平台使用正式构建命令和 lockfile. 在归档前选择适合产物类型的最小校验:

- 可安全启动的 CLI 运行 `--version` 或等价 smoke test.
- CLI 的 `--version` 输出需符合版本显示约定.
- 不适合在 CI 中启动的 GUI 或服务程序, 检查目标文件存在, 可执行权限和 ELF, PE 或 Mach-O 文件格式.
- 应用包或安装镜像检查目录结构, 主程序和必要资源.
- 无法直接运行的交叉编译产物使用模拟器, 加载检查或文件格式检查.

不要为了形式统一而强行执行会启动 GUI, 后台服务或交互流程的二进制.

产物名使用统一格式:

```text
PROJECT-VERSION-PLATFORM-ARCH.EXT
```

例如 `project-1.2.3-linux-x86_64.tar.gz`, `project-1.2.3-windows-aarch64.zip` 和 `project-1.2.3-macos-aarch64.dmg`.

构建 job 为每个矩阵项上传一个独立 artifact, 缺少文件时直接失败. 发布专用 artifact 可以设置较短 retention. Release job 下载并合并全部 artifact, 只对预期扩展名生成统一的 `SHA256SUMS`.

在生成校验和前显式统计归档数量. 在上传 release 前再次统计归档和 `SHA256SUMS` 的总数量. 数量必须与矩阵一致, 防止 glob 静默漏传或混入旧文件.

### 4. 维护 release notes

每个版本维护一个人工编写的 release notes 文件, 默认路径为:

```text
docs/changelog/VERSION.md
```

将该文件作为人工发布说明的唯一来源. 先提交版本号和说明文件, 再让 annotated tag 指向这个 commit, 并直接使用说明文件创建 tag annotation:

```shell
git tag -a "v0.1.0" --cleanup=verbatim \
  -F "docs/changelog/0.1.0.md"
```

必须使用 `--cleanup=verbatim`. Git 默认的 `strip` 模式会把 Markdown 中以 `#` 开头的标题当作注释移除. 不要再用 `-m` 单独维护另一份 tag 正文. 如果 tag 已存在或已推送, 不要直接覆盖, 应先报告 annotation 与版本文件不一致.

人工说明需要覆盖用户可见变化, 兼容性影响和升级操作. 只记录相对上一个发布版本形成净变化的用户可见内容. 如果某个改动在区间内被加入后又移除, 且当前版本相对上一个发布版本没有任何可观察差异, 则该改动完全透明, changelog 不需要体现. 文件缺失或为空时发布直接失败. 使用以下模板, 只保留实际有内容的 section:

```markdown
# PROJECT vVERSION

Date: YYYY-MM-DD

本版本主要带来 ... 使用旧配置或旧 API 的用户请先阅读 Upgrade Notes 再升级.

## Highlights

- 最多 3-5 条最值得关注的用户可见变化.
- 每条使用动词或用户视角开头, 不堆叠内部实现细节.

## Breaking Changes

- 变更内容和影响范围. 迁移方式: 具体操作步骤或文档链接.

## Upgrade Notes

1. 升级前需要完成的备份或检查.
2. 升级后需要执行的操作.
3. 验证升级成功的方法.

## Features

- CLI/API/插件等产品领域: 新增能力及对用户的意义.

## Bug Fixes

- 平台或产品领域: 修复的问题及受影响场景.

## Performance

- 性能变化及可观察到的效果.

## Deprecations

- 废弃内容及计划移除版本, 给出替代方案.
```

- `Highlights` 只放最有价值的 3-5 条, 不重复后面分类里的每一条.
- `Breaking Changes` 必须排在 `Upgrade Notes` 之前, 每条写迁移方式.
- `Features`, `Bug Fixes`, `Performance`, `Deprecations` 等 section 按实际内容保留, 没有内容时不要列出空标题.
- 分类可按产品领域组织, 例如 `CLI:`, `API:`, `插件:`, 不强制使用固定分类.
- 每条只写用户可感知的结果, 合并同一 PR 的 merge 与 squash 痕迹, 避免把完整提交列表再抄入正文.
- 如果项目还维护根目录 `CHANGELOG.md`, 每个版本只放版本号, 日期, 摘要和指向 release 的链接, 不复制完整正文, 保持版本文件为唯一来源.

生成内容前检查上一个 release tag 到当前 tag 之间的 merged PR, 直接提交和实际 diff. Conventional Commits 中的 `feat`, `fix`, `perf`, `docs`, `build`, `ci`, `refactor`, `test`, `chore` 和 `revert` 可用于判断影响类型. 对非规范标题结合 PR metadata 和 diff 判断, 不要只根据措辞猜测.

不要编写自定义自动化脚本生成这份人工说明.

在 workflow 中调用 GitHub Releases API 的 `generate-notes` 接口生成补充内容, 用 `---` 分隔后追加到人工说明之后. Generated notes 用于补充贡献者, PR 列表和完整 diff 链接, 不替代人工说明. `target_commitish` 使用 release job 检出目标 tag 后的 `git rev-parse HEAD`, 不要在手动发布时直接使用触发分支的 `github.sha`.

默认让 GitHub 根据当前 tag 自动选择上一个 tag. 如果 release 序列有断点, 补发版本或基线不能自动推导, 可维护以下可选文件:

```text
docs/changelog/VERSION-base.txt
```

读取后先用 `git check-ref-format` 校验, 再作为 `previous_tag_name` 传给 API. 不要在 workflow 中硬编码一次性的历史 tag.

Release workflow 必须在 checkout 后使用解析得到的 `tag_name` 精确 refetch 远端 tag ref, 再检查对象类型, 提取 annotation, 并与 `docs/changelog/VERSION.md` 做字节比较. `fetch-depth: 0` 不能代替精确 refetch. Lightweight tag, 空 annotation 或内容不一致时直接失败. 手动触发时不得使用指向触发分支的 `github.ref_name`. 具体步骤见 [workflow-patterns.md](references/workflow-patterns.md#发布说明与-annotated-tag).

### 5. 创建或更新 release

所有矩阵构建成功后, 使用 runner 自带的 `gh` CLI 发布. 只给 release job 设置 `contents: write`.

创建或更新 release 时:

- 使用 `--verify-tag` 确认 tag 已存在.
- 标题统一为 `PROJECT vVERSION`, 先移除版本中的可选 `v` 前缀.
- SemVer 包含预发布后缀时设置 prerelease.
- 找不到预期产物或校验和时直接失败.
- release 不存在时使用 `gh release create`.
- release 已存在时使用 `gh release edit` 更新标题和正文, 再用 `gh release upload --clobber` 覆盖产物.
- 需要提前创建 release 时先设为 draft, 产物完整后再公开.

支持更新已有 release, 使失败后的重跑可以收敛到完整状态, 而不是因为 release 已存在再次失败.

### 6. 验证

1. 使用 YAML parser 和项目已有的 action linter 检查 workflow.
2. 确认 branch, PR 和未填写 tag 的手动触发符合第 2 节定义的构建与发布条件.
3. 模拟合法与非法 tag, 确认版本校验和 metadata 读取正确.
4. 在干净环境运行构建, 平台校验和打包命令.
5. 确认全部平台与架构组合都有 tag 专用的校验, 打包和 artifact 上传步骤.
6. 确认 release job 等待全部构建成功, 严格检查产物数量并生成 `SHA256SUMS`.
7. 确认版本化 notes 在创建 tag 前已提交, 遵循 release notes 模板, `git tag -F` 使用 `--cleanup=verbatim`, annotation 保留 Markdown 标题并与文件一致.
8. 确认 checkout 后会精确 refetch 目标 tag object, lightweight tag, 空 annotation 和内容不一致都会失败.
9. 检查可选 base tag 会被校验, generated notes 会用 `---` 分隔并追加在人工正文之后.
10. 检查标题, prerelease 状态, 产物命名和权限范围.
11. 手动填写已有 tag 时确认所有 job 检出该 tag, 且 notes 和 generated notes 都使用该 tag.
12. 检查 release 首次运行会创建, push 与手动重跑会更新正文并覆盖现有产物.
13. 在精确 tag, 非 tag commit 和脏 HEAD 三种状态下, 检查 CLI/TUI/GUI 的版本显示符合约定.

本地检查不能证明所有 GitHub hosted runner 均可用. 明确说明仍需通过真实 tag run 验证的 runner 资格, 平台依赖和发布权限.

## 实现约束

- 遵循仓库现有的 action pinning 策略. 安全要求较高时使用完整 commit SHA.
- 对 tag, 版本和路径变量加引号.
- Bash 步骤使用 `set -euo pipefail`, 数组和 glob 同时处理空匹配.
- PowerShell 步骤使用 `-LiteralPath` 并在缺少文件时抛出错误.
- 多行正文通过文件传递, 不要写入普通单行环境变量.
- 不要在高权限 release job 中构建或执行不可信代码.
- 不要假设 `*-latest` 的 CPU 架构, 应根据官方 runner 文档显式选择.
