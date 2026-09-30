# 待验证事项

本文件集中记录"本地检查无法证明, 必须在真实 GitHub run 或对应平台上确认"的事项.
SKILL.md 与语言模块只引用本文件, 不要在多处重复罗列同一件事.

## 必须在真实 run 上确认

- runner 资格与标签可用性: 本地无法证明 GitHub hosted runner 存在且可排队, 只有真实 run 能确认.
- 平台依赖: 各平台构建工具链 (PowerShell 版本, `tar` / `zip` 命令, 交叉编译的 linker 与 sysroot) 只在对应 runner 上才被真正检验.
- 发布权限: release job 的 `contents: write` 与 `gh` CLI 行为只在真实 tag run 上生效.
- 首次 tag 发布必须覆盖 release job 本体: tag annotation 字节比较, generated notes 拼接, `SHA256SUMS`, `gh release create`. branch 与 PR 运行碰不到这些步骤.

## 环境漂移

- runner 镜像会换代, run 上会出现 annotation (例如 `windows-11-arm` 自 2026-09-21 起默认迁移到 Visual Studio 2026). 这类 annotation 是提示不是失败, 但意味着构建环境会变, 需要记录并复查.
- 已退役或即将退役的标签不要使用 (例如 `macos-13-intel`; `macos-14` 已 deprecated).

## 无法本地实证时的替代路径

非 Windows 开发机上通常没有 `pwsh`, `build-version.ps1`, `dist.ps1` 与 `archive.ps1` 无法本地跑. 此时按以下三步做, 三步都完成才算 Windows 侧已实证:

1. 本地跑 `build-version.sh`, `dist.sh` 与 `archive.sh`, 断言产物命名, 二进制自报版本与无 tag 时的兜底版本号都符合约定.
2. 推送后让 CI 的 windows runner 跑 `dist.ps1` 与 `archive.ps1`.
3. 用 `gh run download` 取回 Windows artifact, 核对压缩包名与内容 (PE 产物存在, 包内只有预期文件).

只做到第 1 步时, 汇报里必须写明"Windows 侧未实证", 不要当作已验证.

## 发布序列的历史遗留

- workflow 建立之前已经推送的 tag 不会再触发 workflow, 因此不会自动补出 release; 手动触发也走不通, 因为那个 commit 上没有 workflow 文件. 处理方式: 手动 `gh release create <tag> --title "<PROJECT> v<version>" --notes-file docs/changelog/<version>.md` 补一个 notes-only release, 或者从下一个版本开始正常走.
- 首个 tag 之前 (仓库还没有任何版本 tag) 的 branch 与 PR 运行靠包版本加短 hash 兜底, Go 用 `0.0.0` 占位, 因此不会再卡在这里. 但首个正式 release 仍然必须在 workflow 已经存在于该 commit 的前提下打 tag, 也就是先把包含 workflow 与 `docs/changelog/<version>.md` 的提交推上去, 再打 annotated tag 并 push; 不要为了"让 CI 先跑过"把 workflow 文件留到首 tag 之后补.
