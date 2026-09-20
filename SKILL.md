---
name: create-github-release-flow
description: 创建或修改 GitHub Actions CI 和 tag 发布流程. 适用于仓库需要版本校验, 手动发布, release notes, 多平台产物打包或 GitHub Release 自动发布时. 打 tag push 必读.
---

# 创建 GitHub Release 流

## 目标

先确认项目现有的 CI, 构建, 打包和版本规则, 并判断分发方式, 再实现以下流程.

二进制/应用:

```text
release preparation -> write VERSION.md -> commit -> annotated tag from VERSION.md -> push
branch/PR -> build matrix -> validate/package -> upload artifact
tag -> validate version -> build matrix -> validate/package -> notes/checksums -> create/update release
manual branch -> build matrix -> validate/package -> upload artifact
manual tag -> validate version -> build matrix -> validate/package -> notes/checksums -> create/update release
```

库分发 (Rust lib crate, 以及 Python package, npm package, Go module 等同类形式):

```text
release preparation -> write VERSION.md -> commit -> annotated tag from VERSION.md -> push
branch/PR -> test/build
tag -> validate version -> test/build -> notes -> create/update release
manual branch -> test/build
manual tag -> validate version -> test/build -> notes -> create/update release
```

默认让普通 CI, tag 发布和手动触发复用同一套检查. 普通 branch, PR 和未填写 tag 的手动触发不创建 release. Tag push 或显式指定已有 tag 的手动触发执行版本校验和发布. 如果仓库已有独立发布 workflow, 可以保留分离结构, 但不要复制构建逻辑.

构建, 校验或 (若有) 产物完整性检查失败时不得创建公开 release.

## 工作流程

### 1. 确认项目规则

先判断项目如何分发, 再读现有 CI 和脚本:

- 二进制/应用: 用户从 GitHub Release 或安装包获取 CLI, TUI, GUI 或预编译归档. 使用下文的运行时版本号显示, 跨平台打包和 artifact 规则.
- 库: 用户通过语言生态的包管理器获取, 例如 Rust lib crate, Python package, npm package, Go module. 不套用运行时版本号显示规则, 也不默认做跨平台二进制打包.
- 混合项目只对实际以二进制方式分发的部分套用版本显示和打包规则. 判断以用户获取方式为准, 不要只看构建清单里有没有 bin 或 lib target.

阅读项目说明, 现有 CI, task runner 和打包脚本, 确认:

- tag 格式和版本来源.
- 正式构建或测试命令与 lockfile.
- 项目当前或可用的依赖与构建缓存机制, 包括专用缓存 action 和缓存路径.
- branch, PR 和 tag 当前执行的 job.
- release notes, changelog 和历史 release 的维护方式.
- 二进制/应用: 二进制, 应用包和归档的输出路径; 各平台的编译 target, runner 和运行时兼容要求; CLI, TUI, GUI 等展示版本号的交互位置及其版本信息的生成方式.
- 库: 包 metadata 中的版本字段, 现有测试矩阵, 以及是否已有 crates.io, PyPI, npm 等发布方式.

仅当项目以二进制/应用方式分发, 且 CLI, TUI, GUI 等可能展示版本号时, 发布构建产物中的这些交互位置 (如 `--version`, About 对话框) 必须显示当前构建版本并标注构建 commit:

- 构建 commit 恰好是某个版本 tag 时, 直接显示该 tag, 例如 `v1.2.3`.
- 构建处于非 tag commit 时, 在最近一个版本 tag 后追加 `-` 和 7 位短 hash, 例如 `v1.2.3-a1b2c3d`.
- HEAD 工作区有未提交改动时, 改用 `^` 分隔, 例如 `v1.2.3^a1b2c3d`.
- 基础版本号样式跟随最近一个版本 tag, 不要固定假设带 `v` 前缀或三段式 SemVer.
- 日常开发构建 (不经 `just dist` 或 CI 的直接构建) 不注入版本信息, 版本号显示 `dev-build`.

> 版本号显示必须自动生成, 而不是手动编辑写死.
> 库分发不要把 git describe 或短 hash 写入包版本. 包版本保持 metadata 中的稳定版本, 由 tag 与其严格对齐.

二进制/应用复制 [build-version.sh](references/build-version.sh) 和 [build-version.ps1](references/build-version.ps1) 到 `scripts/`, 按文件开头说明改占位符.

版本自动嵌入逻辑 (如 Rust build script/vergen, Go `-ldflags -X`, CMake 构建期读取 git 等同类机制) 默认关闭, 只在发布构建路径通过显式开关 (如环境变量) 打开: 本地由 `just dist` 注入脚本结果, CI 用同一环境变量注入 `build_version`. 不要让普通开发构建无条件读取 `.git`, 否则每次 commit 都会使增量编译缓存失效, `target` 等构建目录持续膨胀.

优先调用项目已有的 task runner 或打包脚本. 平台专用打包包含应用目录, 图标, metadata 或签名准备时, 将逻辑放在项目脚本中, 不要把完整实现内联到 workflow.

仅在项目需要平台二进制打包, 并且需要新增 Just recipe 时, 统一提供 `just dist`. 该 recipe 根据当前运行平台执行相应构建, 必须不接受任何参数, 不要声明 `*args` 或位置参数, 也不要新增 `package-macos`, `package-windows` 等按平台命名的 recipe. 库分发不要为了走发布流程而新增 `just dist`.

桌面应用默认形态 (安装版) 就是 `just dist` 的产物. 只有当项目明确提供便携版形态时, 才额外新增同样不接受参数的 `just dist-portable`; 不要用参数或环境变量在两种形态之间切换, 也不要新增按平台命名的 recipe.

二进制/应用示例, 为同一 `dist` recipe 添加互斥的平台属性, 并注入构建版本:

```justfile
# 根据当前平台生成发布产物.
[windows]
[script('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')]
dist:
    $ErrorActionPreference = 'Stop'
    $version = (& 'scripts/build-version.ps1' | Out-String).Trim()
    $env:PROJECT_BUILD_VERSION = "v$version"
    & 'scripts/dist-windows.ps1'
    if ($LASTEXITCODE) { exit $LASTEXITCODE }

# 根据当前平台生成发布产物.
[macos]
dist:
    PROJECT_BUILD_VERSION="v$(bash scripts/build-version.sh)" ./scripts/dist-macos.sh

# 根据当前平台生成发布产物.
[linux]
dist:
    PROJECT_BUILD_VERSION="v$(bash scripts/build-version.sh)" ./scripts/dist-linux.sh
```

实现具体 YAML 片段时按需读取 [workflow-patterns.md](references/workflow-patterns.md), 不要一次性复制所有示例.

### 2. 组织 CI, tag 与手动触发

根据项目惯例匹配 `v1.2.3` 或 `1.2.3` 等 tag. Tag pattern 只负责减少无效运行, workflow 内仍要严格校验版本.

如果项目文件中保存版本号, 使用结构化 metadata 命令读取, 规范化 tag 后严格比较. Rust 项目优先使用 `cargo metadata --locked --no-deps --format-version 1`, 不要用文本正则读取 `Cargo.toml`. 如果 tag 是唯一版本来源, 不要额外维护第二份版本状态.

添加 `workflow_dispatch` 和可选字符串 input `tag`. 空值表示对用户在 GitHub UI 或 API 中选择的 ref 运行 CI, 不创建 release; 二进制/应用会构建并上传 Actions artifact, 库分发默认只跑测试或编译检查, 不要为了形式上传空 artifact. 非空值表示发布该已有 tag. 不要让手动发布隐式使用触发 workflow 的 branch commit.

在 `version` job 的第一个步骤统一解析并输出:

- `is_release`: tag push 或手动提供 tag 时为 `true`.
- `tag_name`: tag push 的 ref name 或手动输入的 tag.
- `source_ref`: tag 发布时为 `refs/tags/TAG`, 其他情况为当前事件的 `github.sha`.
- `version`: 仅在 `is_release` 为 `true` 且版本校验成功后输出.
- `build_version`: 二进制/应用必须始终输出. release 时等于 `version`; 非 release 时用脚本 stdout. 库分发不需要这个 output.

手动 tag 先用 `git check-ref-format "refs/tags/$TAG_NAME"` 校验格式, 再检出完整 tag. Tag 不存在时必须在构建开始前失败.

当普通 CI 和发布共用 workflow 时:

- `version` job 保持可被构建或测试 job 依赖, 但版本校验步骤只在 `is_release` 为 `true` 时执行.
- 构建或测试 job 使用 `source_ref` 检出代码, 确保手动发布构建的是目标 tag.
- 矩阵在 branch, PR, tag 和手动触发上执行.
- 二进制/应用: 产物校验, 打包和 artifact 上传步骤默认在上述全部触发上执行, 不要只在 release 或 `workflow_dispatch` 时才上传. 非 release 运行没有校验后的 `version` output, 产物命名改用 `build_version`.
- 库分发: 矩阵按项目测试需求覆盖平台, 不要为了归档去扩 6 架构打包矩阵; 默认不打包二进制, 不上传发布归档.
- release job 只在 `is_release` 为 `true` 时执行, 并依赖版本校验和全部矩阵检查.

为每个 ref 或手动输入 tag 设置 concurrency group, 并使用 `cancel-in-progress: false`, 防止同一 tag 的 push 和手动发布并发修改 release.

### 3. 构建, 校验并打包

构建或测试 job 应配置依赖与构建缓存, 但缓存只用于加速, 不能作为发布正确性来源:

- 优先使用该语言或工具链已验证的专用缓存 action, 例如 setup action 内置缓存或社区广泛使用的专用 cache action.
- 没有可用专用机制时, 回退到 `actions/cache@v6`, 缓存路径覆盖包管理器缓存和构建缓存, 不缓存发布产物.
- `actions/cache@v6` 的 key 包含 runner 系统, 矩阵架构和 lockfile hash, 并使用 `restore-keys` 回退; 不同平台和架构必须隔离.
- 缓存 miss 或恢复失败不能导致构建失败, 干净环境必须能完整构建.
- 二进制/应用: 最终产物必须通过 artifact 汇总, 不依赖缓存保存发布文件.

库分发:

- 不要求 `--version` smoke test.
- CI 以测试, 类型检查和正式构建命令为主, 平台覆盖跟随项目现有测试需求.
- 不要新增跨平台二进制归档, 不要上传发布用 artifact, 不要生成 SHA256SUMS.
- 不要把自动生成的构建版本号写入 Cargo.toml, pyproject.toml, package.json 等包版本字段.
- 若项目已有发布到 crates.io, PyPI, npm 等的脚本或 recipe, 优先复用; 不要在高权限 release job 里内联一套新的发布实现, 也不要为了 GitHub Release 再打一份库归档.

跨平台归档矩阵, 产物命名, SHA256SUMS 和 `just dist` 只适用于二进制/应用. 默认覆盖以下构建矩阵:

| 平台 | 架构 | 常见归档 |
| --- | --- | --- |
| Linux | `x86_64` | CLI 使用 `.tar.gz`; 桌面应用安装版 `.tar.gz` (`-setup`), 可选便携版 `.tar.gz` (`-portable`) |
| Linux | `aarch64` | 同上 |
| Windows | `x86_64` | CLI 使用 `.zip`; 桌面应用安装版 `.exe` (`-setup`, Inno Setup), 可选便携版 `.zip` (`-portable`) |
| Windows | `aarch64` | 同上 |
| macOS | `x86_64` | CLI 使用 `.tar.gz`, 桌面应用使用 `.dmg` |
| macOS | `aarch64` | CLI 使用 `.tar.gz`, 桌面应用使用 `.dmg` |

桌面应用默认按安装版分发, 便携版只在项目明确提供该形态时才出产物. 安装布局, 安装器要求与自动更新落地方式见 desktop-app-skill.

在实现时查阅 GitHub 官方 runner 文档, 确认当前可用的 runner 标签和仓库资格. 优先使用对应系统和架构的原生 runner. 无法原生构建时使用项目成熟的交叉编译工具链, 并明确 linker, sysroot 和系统库要求.

> 注: 不要使用已经退役的 runner, 比如 macos-13-intel 等.

每个平台使用正式构建命令和 lockfile. 在归档前选择适合产物类型的最小校验:

- 可安全启动的 CLI 运行 `--version` 或等价 smoke test.
- CLI 的 `--version` 输出需符合版本显示约定.
- 不适合在 CI 中启动的 GUI 或服务程序, 检查目标文件存在, 可执行权限和 ELF, PE 或 Mach-O 文件格式.
- 应用包或安装镜像检查目录结构, 主程序和必要资源.
- macOS 桌面应用 dmg 必须包含指向 `/Applications` 的符号链接和应用的 `.app` 包, 校验方式见 [workflow-patterns.md](references/workflow-patterns.md#平台产物校验).
- Windows 桌面应用安装器检查 PE 文件头, 并在 windows runner 上用自动更新同款的静默参数 (`/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS`) 装到临时目录, 断言主程序与随附 dll 都已就位, 再用该目录里的 `unins000.exe` 静默卸载. 这一步同时验证了自动更新要走的静默路径, 校验片段见 [workflow-patterns.md](references/workflow-patterns.md#平台产物校验).
- Linux 桌面应用安装包断言含 `install.sh` 与 `payload/` 下的主程序, 再用 `install.sh --silent --prefix <临时目录>` 装一次, 断言可执行位, desktop 项与图标都落在该前缀内; `install.sh` 因此必须支持 `--prefix`.
- 无法直接运行的交叉编译产物使用模拟器, 加载检查或文件格式检查.

不要为了形式统一而强行执行会启动 GUI, 后台服务或交互流程的二进制.

产物名使用统一格式:

```text
PROJECT-VERSION-PLATFORM-ARCH[-VARIANT].EXT
```

例如 `project-1.2.3-linux-x86_64.tar.gz`, `project-1.2.3-windows-aarch64.zip` 和 `project-1.2.3-macos-aarch64.dmg`. 非 release 运行使用 `build_version`, 例如 `project-1.2.3-a1b2c3d-linux-x86_64.tar.gz`. Actions artifact 名使用同一格式但不带扩展名, 例如 `project-1.2.3-a1b2c3d-linux-x86_64`, 不要写成 `project-aarch64`.

VARIANT 是可选段, 只用于同一平台同一架构存在多种分发形态的桌面应用: 安装版用 `setup`, 便携版用 `portable`, 例如 `project-1.2.3-windows-x86_64-setup.exe`, `project-1.2.3-linux-x86_64-portable.tar.gz`, 以及对应的 Actions artifact 名 `project-1.2.3-windows-x86_64-setup`. CLI 与库产物, 以及只有单一形态的 macOS 桌面应用 dmg 都不带这一段. 形态定义与安装器细节见 desktop-app-skill.

平台无关的托管运行时产物, 例如 .NET dll 程序集和 Java jar/war, 不强行添加 PLATFORM-ARCH 后缀, 直接命名为 PROJECT-VERSION.EXT, Actions artifact 名同理, 例如 `project-1.2.3.jar` 与 `project-1.2.3`.

构建 job 为每个矩阵项上传一个独立 artifact, 缺少文件时直接失败. 该步骤不限于 tag 或手动触发. 发布专用 artifact 可以设置较短 retention. Release job 下载并合并全部 artifact, 只对预期扩展名生成统一的 `SHA256SUMS`. SHA256SUMS 和 GitHub Release 只在 `is_release` 为 `true` 时生成.

在生成校验和前显式统计归档数量. 在上传 release 前再次统计归档和 `SHA256SUMS` 的总数量. 数量必须与矩阵一致, 防止 glob 静默漏传或混入旧文件. 桌面应用按项目实际提供的形态计数: 只出安装版时每个平台架构一项, 同时提供便携版时再加一项, 期望值按矩阵展开后的总数填写.

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

从版本号同步, notes 文件, annotated tag 到 push 分支和 tag, 全程在一次提权中执行完毕, 不要逐步拆成多次提权. 实际操作是把版本号改动和 `docs/changelog/VERSION.md` 一起 stage 并 commit, 再用该文件创建 annotated tag, 最后 push 分支和 tag. 命令写成一条命令链, 每个 git 命令独占一行, 用 `&&` 连接, 例如版本存于 Cargo.toml 的项目发布 v0.1.0:

```shell
git add Cargo.toml Cargo.lock docs/changelog/0.1.0.md &&
git commit -m "chore(release): v0.1.0" &&
git tag -a "v0.1.0" --cleanup=verbatim -F "docs/changelog/0.1.0.md" &&
git push origin main &&
git push origin "v0.1.0"
```

- `git add` 只 stage 版本号改动和对应 notes 文件, 版本文件按项目实际替换, 如 `pyproject.toml`, `package.json` 及各自 lockfile; tag 是唯一版本来源时只 add notes 文件.
- commit message 跟随项目现有 release commit 风格, 不固定使用 `chore(release)`.
- `git tag` 必须保持上文 annotated tag 形式, `--cleanup=verbatim` 和 `-F` 指向同一个 notes 文件.
- 分支名以项目默认分支为准. 版本号尚未同步时, 同步 commit 就是这条链中的 commit, 不要拆到链外.

提权前完成全部检查并确认 annotation 与版本文件一致, 提权执行中只包含这条 git 命令链, 不混入其他任务.

人工说明需要覆盖用户可见变化, 兼容性影响和升级操作. 只记录相对上一个发布版本形成净变化的用户可见内容. 库分发侧重 API, 兼容性和迁移; 没有安装包时, Upgrade Notes 写依赖版本和 API 迁移即可, 不要按二进制安装包的口吻写升级步骤. 如果某个改动在区间内被加入后又移除, 且当前版本相对上一个发布版本没有任何可观察差异, 则该改动完全透明, changelog 不需要体现. 文件缺失或为空时发布直接失败. 使用以下模板, 只保留实际有内容的 section:

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

矩阵检查成功后, 使用 runner 自带的 `gh` CLI 发布. 只给 release job 设置 `contents: write`.

创建或更新 release 时:

- 使用 `--verify-tag` 确认 tag 已存在.
- 标题统一为 `PROJECT vVERSION`, 先移除版本中的可选 `v` 前缀.
- SemVer 包含预发布后缀时设置 prerelease.
- 二进制/应用: 找不到预期产物或校验和时直接失败. release 不存在时使用 `gh release create`. release 已存在时使用 `gh release edit` 更新标题和正文, 再用 `gh release upload --clobber` 覆盖产物. 需要提前创建 release 时先设为 draft, 产物完整后再公开.
- 库分发: 创建或更新 notes-only GitHub Release, 不要因为没有归档或 SHA256SUMS 而失败, 也不要上传空的 SHA256SUMS. release 不存在时 `gh release create` 不带资产; 已存在时只用 `gh release edit` 更新标题和正文.

支持更新已有 release, 使失败后的重跑可以收敛到完整状态, 而不是因为 release 已存在再次失败.

### 6. 验证

按分发类型核对应检查项. 库分发跳过产物, checksum 和运行时版本显示相关项.

1. 使用 YAML parser 和项目已有的 action linter 检查 workflow.
2. 确认 branch, PR 和未填写 tag 的手动触发不会创建 release. 二进制/应用会构建并上传 artifact; 库分发会跑测试或编译检查, 且没有为形式而上传的空 artifact.
3. 模拟合法与非法 tag, 确认版本校验和 metadata 读取正确.
4. 在干净环境运行正式检查命令. 二进制/应用还要跑平台校验和打包命令.
5. 二进制/应用: 确认全部平台与架构组合在 branch, PR, tag 和手动触发上都有校验, 打包和 artifact 上传步骤, 且仅 tag 发布会创建 release; 桌面应用还要确认项目实际提供的每个形态都有各自的打包与校验步骤. 库分发: 确认测试矩阵覆盖项目现有需求, 且仅 tag 发布会创建 release.
6. 二进制/应用: 确认 release job 等待全部构建成功, 严格检查产物数量并生成 `SHA256SUMS`; 桌面应用的数量期望值按安装版与 (若有) 便携版展开后的总数填写. 库分发: 确认 release job 等待全部检查成功, 且不会因缺少归档失败.
7. 确认版本化 notes 在创建 tag 前已提交, 遵循 release notes 模板, `git tag -F` 使用 `--cleanup=verbatim`, annotation 保留 Markdown 标题并与文件一致.
8. 确认 checkout 后会精确 refetch 目标 tag object, lightweight tag, 空 annotation 和内容不一致都会失败.
9. 检查可选 base tag 会被校验, generated notes 会用 `---` 分隔并追加在人工正文之后.
10. 检查标题, prerelease 状态和权限范围. 二进制/应用还要检查产物命名, 包括 Actions artifact 名, 桌面应用确认安装版与便携版都带上对应的变体段; 库分发确认没有多余归档资产.
11. 手动填写已有 tag 时确认所有 job 检出该 tag, 且 notes 和 generated notes 都使用该 tag.
12. 检查 release 首次运行会创建, push 与手动重跑会更新正文. 二进制/应用还会覆盖现有产物.
13. 仅二进制/应用: 在精确 tag, 非 tag commit 和脏 HEAD 三种状态下, 检查 CLI/TUI/GUI 的版本显示符合约定; 日常开发构建显示 `dev-build`, 且构建脚本不会因 `.git` 变化触发重编. 库分发确认包版本仍是 metadata 中的稳定版本, 没有被写入 git hash.
14. 确认缓存机制选择顺序正确, 专用缓存与项目实际匹配, 没有重复缓存同一路径, 且 fallback 缓存 miss 时仍能完整构建.
15. 不需要在项目当中编写发布工作流的文档和发布新版本的操作说明, agent 通过阅读此 skill 可以重新获取相关信息. 也不需要发布新版本的 just recipe, 需要 agent 手动实现.

本地检查不能证明所有 GitHub hosted runner 均可用. 明确说明仍需通过真实 tag run 验证的 runner 资格, 平台依赖和发布权限.

## 实现约束

- 遵循仓库现有的 action pinning 策略. 安全要求较高时使用完整 commit SHA.
- 对 tag, 版本和路径变量加引号.
- Bash 步骤使用 `set -euo pipefail`, 数组和 glob 同时处理空匹配.
- PowerShell 步骤使用 `-LiteralPath` 并在缺少文件时抛出错误.
- 多行正文通过文件传递, 不要写入普通单行环境变量.
- 不要在高权限 release job 中构建或执行不可信代码.
- 依赖和构建缓存只配置在低权限构建或测试 job, 不要在高权限 release job 中恢复或写入缓存.
- 不要假设 `*-latest` 的 CPU 架构, 应根据官方 runner 文档显式选择.
