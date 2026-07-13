---
name: create-github-release-flow
description: 创建或修改由 tag 触发的 GitHub Actions 跨平台自动发布流程, 为 Windows, Linux 和 macOS 构建 x86_64/aarch64 产物, 创建 GitHub Release, 并将 feat, fix, perf 等 Conventional Commits 和非规范提交文本整理成规范的 release notes.
---

# 创建 GitHub Release 流

## 目标

先确认项目现有的构建和版本规则, 再实现以下流程:

```text
tag -> validate -> build matrix -> package -> release
```

默认使用 tag push 触发. 构建或校验失败时不得创建公开 release.

## 工作流程

### 1. 确认项目规则

阅读项目说明, 现有 CI 和构建入口, 确认:

- tag 格式和版本来源.
- 正式构建命令与 lockfile.
- 产物目录和文件名.
- 各平台的编译 target 和运行时兼容要求.

优先调用项目已有的 task runner 或发布脚本, 不要在 workflow 中复制其内部逻辑.

### 2. 校验 tag

根据项目惯例匹配 `v1.2.3` 或 `1.2.3` 等 tag. Tag pattern 只负责减少无效运行, workflow 内仍要校验版本格式.

如果项目文件中保存版本号, 使用结构化 metadata 命令读取, 规范化 tag 后严格比较. 如果 tag 是唯一版本来源, 不要额外维护第二份版本状态.

为每个 tag 设置独立的 concurrency group, 并使用 `cancel-in-progress: false`.

### 3. 构建并发布

默认覆盖以下构建矩阵:

| Platform | Architecture | Archive |
| --- | --- | --- |
| Linux | `x86_64` | `.tar.gz` |
| Linux | `aarch64` | `.tar.gz` |
| macOS | `x86_64` | `.tar.gz` |
| macOS | `aarch64` | `.tar.gz` |
| Windows | `x86_64` | `.zip` |
| Windows | `aarch64` | `.zip` |

在实现时查阅 GitHub 官方 runner 文档, 确认当前可用的 runner 标签和仓库资格. 优先使用对应系统和架构的原生 runner. 无法原生构建时使用项目成熟的交叉编译工具链, 并明确 linker, sysroot 和系统库要求.

每个平台使用正式构建命令, 在归档前运行 `--version` 或等价的最小 smoke test. 无法直接运行交叉编译产物时, 使用模拟器或项目提供的加载检查.

产物名使用统一格式:

```text
PROJECT-VERSION-PLATFORM-ARCH.EXT
```

例如 `project-1.2.3-linux-x86_64.tar.gz` 和 `project-1.2.3-windows-x86_64.zip`.

构建 job 上传归档, release job 下载全部归档并生成统一的 `SHA256SUMS`. 所有构建成功后, 使用 runner 自带的 `gh` CLI 创建 release 并上传产物.

创建 release 时:

- 使用 `--verify-tag` 确认 tag 已存在.
- 只给 release job 设置 `contents: write`.
- 找不到预期产物时直接失败.
- SemVer 包含预发布后缀时设置 prerelease.
- 需要提前创建 release 时先设为 draft, 产物完整后再公开.

### 4. 规范 release notes

Release 标题统一为:

```text
PROJECT vVERSION
```

先移除版本中的可选 `v` 前缀, 避免生成 `vv1.2.3`.

变更描述遵循 Conventional Commits 格式:

```text
<type>[optional scope][!]: <description>
```

例如:

```text
feat(cli): add JSON output
fix(build): package the Windows ARM64 binary
perf(parser): reduce allocation during startup
feat(api)!: remove the deprecated v1 endpoint
```

使用以下类型组织 release notes:

- `feat` -> `Features`
- `fix` -> `Fixes`
- `perf` -> `Performance`
- `docs` -> `Documentation`
- `build(deps)` 或 `chore(deps)` -> `Dependencies`
- `refactor`, `test`, `build`, `ci`, `chore` -> `Maintenance`
- `revert` -> `Reverts`

带 `!` 的描述或包含 `BREAKING CHANGE:` footer 的提交归入 `Breaking Changes`, 并说明迁移方式. 不要把 breaking change 仅留在普通 `Features` 或 `Fixes` 分类中.

不要只依赖 GitHub generated release notes 或 PR label 自动分类. 生成正文前执行以下归一化流程:

1. 确定上一个 release tag, 收集该 tag 到当前 tag 之间的 merged PR 和直接提交.
2. 对符合 Conventional Commits 的标题直接保留类型, scope 和 breaking change 标记.
3. 对不符合规范的文本, 依次参考关联 PR 的标题, label, 正文和实际 diff 推断类型与 scope.
4. 将推断结果改写成 `<type>(<scope>): <description>` 形式的 release 条目. 只改写 release notes, 不改写 Git 历史.
5. 合并同一 PR 的 merge commit 与 squash commit, 避免重复条目. 保留 PR 编号和贡献者信息.
6. 将无法可靠识别但确属内部维护的条目归为 `chore`. 不要把未知变更猜成 `feat` 或 `fix`.

推断类型时按实际影响判断:

- 新增用户能力归为 `feat`.
- 修正错误行为归为 `fix`.
- 只改善性能归为 `perf`.
- 只修改文档或测试归为 `docs` 或 `test`.
- 依赖, 构建和 CI 变更归为 `build(deps)`, `chore(deps)`, `build` 或 `ci`.
- 不改变外部行为的代码整理归为 `refactor`.

优先使用 GitHub API 或 `gh` 的结构化输出关联 PR 和提交. 不要仅用正则解析 merge commit 文本. 如果仓库使用 squash merge, 要求 PR 标题符合 Conventional Commits, 使后续发布无需再次推断.

将归一化结果写入 `release-notes.md`, 再通过 `gh release create --notes-file` 发布. Generated release notes 可以补充贡献者和完整 diff 链接, 但不得与归一化条目重复.

维护 `.github/release.yml`, 让 PR label 与上述 Conventional Commits 类型对应, 作为分类提示和校验依据.

使用稳定且面向用户的分类:

- `Breaking Changes`
- `Features`
- `Fixes`
- `Performance`
- `Documentation`
- `Dependencies`
- `Maintenance`
- `Reverts`

只保留实际存在的分类. 不要生成空章节, 不要重复 PR 列表, 不要使用 `Bug fixes and improvements` 等缺少信息的套话.

如果项目维护人工 changelog, 优先使用对应版本的 changelog. Annotated tag 描述只能作为简短导语, 不要与 changelog 或 generated notes 重复.

仅在确有内容时增加:

- `Highlights`: 最重要的用户可见变化.
- `Breaking Changes`: 不兼容变化和迁移方式.
- `Upgrade Notes`: 用户必须执行的升级操作.

Release notes 应保留 `feat`, `fix` 等类型前缀, 并说明用户获得了什么变化. 内部 CI, 重构或维护细节仅在影响安装, 兼容性或安全性时出现.

### 5. 验证

1. 使用 YAML parser 和项目已有的 action linter 检查 workflow.
2. 模拟合法与非法 tag, 确认版本校验正确.
3. 在干净环境运行构建, smoke test 和归档命令.
4. 确认 6 个平台与架构组合都有构建, smoke test 和归档步骤.
5. 确认 release job 等待全部构建成功, 并在缺少产物时失败.
6. 检查标题, notes 分类, prerelease 状态和产物命名.
7. 检查 release 条目符合 Conventional Commits 格式, 且 `feat`, `fix` 和 breaking change 分类正确.
8. 使用包含规范提交, 非规范提交, merge commit 和直接提交的 tag 区间验证归一化结果, 确认没有遗漏或重复条目.

本地检查不能证明所有 GitHub hosted runner 均可用. 明确说明仍需通过真实 tag run 验证的部分.

## 实现约束

- 遵循仓库现有的 action pinning 策略. 安全要求较高时使用完整 commit SHA.
- 对 tag, 版本和路径变量加引号.
- 多行正文通过文件传递, 不要写入普通单行环境变量.
- 不要在高权限 release job 中构建或执行不可信代码.
- 不要假设 `*-latest` 的 CPU 架构, 应根据官方 runner 文档显式选择.
