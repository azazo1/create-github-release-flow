# C# / .NET 语言模块

按 SKILL.md 的分派表读取本模块. 这里只写 .NET 的落地方式; 流程, release notes 治理, tag 与 release 规则见 SKILL.md, 语言无关的 YAML 骨架见 [workflow-patterns.md](../workflow-patterns.md).

## 分发形态判定

| 形态 | 判定依据 | 产物命名 | 套用规则 |
| --- | --- | --- | --- |
| 库 | 打包成 NuGet 包供他人引用 | `PROJECT-VERSION.nupkg` | notes-only release, 不打包二进制 |
| 框架依赖程序集 | 用户需要自备运行时, 产物与平台无关 | `PROJECT-VERSION.zip` | 下面的归档规则, 命名不加平台与架构 |
| self-contained RID 二进制 | 目标平台自带运行时 | `PROJECT-VERSION-PLATFORM-ARCH.zip` | 完整跨平台归档矩阵 |
| 桌面 GUI | WPF 或 WinForms 等项目本身就只支持 Windows | 按实际平台 | 矩阵收敛到 Windows, 不要虚构其他平台产物 |

`<TargetFramework>` 只决定 API 面, 不决定是否需要平台架构后缀; 后缀由是否 self-contained 与是否含原生依赖决定.

## 版本来源与 tag 校验

版本在 `Version` 或 `VersionPrefix` 属性里, 可能来自 `csproj` 或 `Directory.Build.props`. 用 MSBuild 求值结果读取, 不要正则扫 `csproj`:

```yaml
- name: 校验 tag 与包版本
  id: release_version
  if: steps.release_context.outputs.is_release == 'true'
  env:
    TAG_NAME: ${{ steps.release_context.outputs.tag_name }}
  shell: bash
  run: |
    set -euo pipefail
    package_version="$(dotnet msbuild src/PROJECT/PROJECT.csproj -getProperty:Version)"
    expected_tag="v$package_version"

    if [[ "$TAG_NAME" != "$expected_tag" ]]; then
      echo "tag $TAG_NAME 与包版本 $package_version 不一致" >&2
      exit 1
    fi

    echo "version=$package_version" >> "$GITHUB_OUTPUT"
```

- `-getProperty` 需要 .NET SDK 8 及以上; 更早版本用 `-getProperty:Version` 的等价参数或先 `dotnet build` 再读程序集属性.
- 库分发使用 `PackageVersion` 时, 它必须与 tag 对齐, 并且不能带 commit hash.
- 一个仓库有多个要发布的包时, 逐个求值确认一致.

## 版本注入与运行时显示

复制 [assets/dotnet/Directory.Build.props](assets/dotnet/Directory.Build.props) 到项目根目录. 它把 `PROJECT_BUILD_VERSION` 注入程序集的 `AssemblyInformationalVersion`, 不触碰 `Version` 与 `PackageVersion` 这类包版本字段:

```shell
dotnet publish src/PROJECT/PROJECT.csproj -c Release \
  -p:PROJECT_BUILD_VERSION=v1.2.3 \
  -o dist/stage
```

- 版本展示读取 `AssemblyInformationalVersionAttribute`; 需要在代码里取:

```csharp
using System.Reflection;

var version = Assembly.GetEntryAssembly()
    ?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
    ?.InformationalVersion ?? "dev-build";
```

- 该 props 关掉了 SDK 自带的 `GenerateAssemblyInformationalVersionAttribute`, 否则会与本文件生成的重名并报重复属性.
- 属性文件在 `IntermediateOutputPath` 下生成, 属于构建中间产物, 不要提交.
- 库分发不要注入构建版本号, 包版本以 `Version` / `PackageVersion` 为准.
- 生成属性文件与 `dotnet publish` 的配合需要真实构建确认一次: 若项目自定义了 `BaseIntermediateOutputPath` 或重写了 `CoreCompile`, 要复核生成目标仍然在编译前触发.

## 依赖与构建缓存

```yaml
- name: 准备 .NET
  uses: actions/setup-dotnet@v6
  with:
    global-json-file: global.json
    cache: true
    cache-dependency-path: "**/packages.lock.json"
```

- 用 `global.json` 固定 SDK 版本, 不要在 workflow 里写死 SDK 版本号.
- 让 `setup-dotnet` 的缓存生效需要项目启用锁定文件 (`RestorePackagesWithLockFile` 为 `true` 并提交 `packages.lock.json`); 没有锁定文件时缓存命中率很低, 此时宁可不配缓存.
- 需要通用缓存时用 `actions/cache`, 路径覆盖 `~/.nuget/packages`, key 包含 runner 系统, 架构与锁定文件 hash.

## 构建与测试命令

```shell
dotnet restore --locked-mode
dotnet build -c Release --no-restore
dotnet test -c Release --no-build
dotnet format --verify-no-changes        # 只报告不修改
```

- 有锁定文件时用 `--locked-mode`, 保证还原结果与提交一致.
- 发布命令是 `dotnet publish`, 与 `build` 分开, 避免把中间产物当成发布产物.
- 格式检查只报告; 不要用 `dotnet format` 直接改写工作区.

## 平台目标与 runner

| 平台 | 架构 | runner 标签 | RID | 归档 |
| --- | --- | --- | --- | --- |
| Linux | x86_64 | `ubuntu-24.04` | `linux-x64` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `linux-arm64` | `.tar.gz` |
| macOS | aarch64 | `macos-15` | `osx-arm64` | `.tar.gz` |
| macOS | x86_64 | `macos-15-intel` | `osx-x64` | `.tar.gz` |
| Windows | x86_64 | `windows-2025` | `win-x64` | `.zip` |
| Windows | aarch64 | `windows-11-arm` | `win-arm64` | `.zip` |

- 每个 RID 用对应的原生 runner 构建, 不要在单个 runner 上交叉发布全部 RID: 原生依赖与运行时包在交叉场景下容易出问题, 且产物无法就地冒烟检查.
- WPF 与 WinForms 这类 Windows-only 项目只保留 `windows-2025` 与 `windows-11-arm`.
- self-contained 产物体积明显更大, 只有在目标机器不保证有对应运行时时才选用.

## 归档与打包

复制 [assets/dotnet/dist.sh](assets/dotnet/dist.sh) 到 `scripts/dist.sh`, 同时复制 [../archive.sh](../archive.sh) 与 [../build-version.sh](../build-version.sh); Windows 侧复制 [assets/dotnet/dist.ps1](assets/dotnet/dist.ps1), [../archive.ps1](../archive.ps1), [../build-version.ps1](../build-version.ps1).

- 只改顶部常量: `PROJECT_NAME`, `PROJECT_FILE`, `BINARY_NAME`, `SMOKE_ARGS`.
- `BUILD_MODE=self-contained` 出带平台架构后缀的 RID 二进制; `BUILD_MODE=framework-dependent` 出平台无关的 dll 程序集, 交给 `archive.sh` 时设 `PLATFORM_INDEPENDENT=1`, 得到 `PROJECT-VERSION.zip`.
- 框架依赖产物要确保运行方式对用户可见: 归档内附一份说明, 或在 Release notes 里写清需要的运行时版本.
- `justfile` 的 `dist` 与 Go 模块给出的形状一致, 只把构建命令换成 `dotnet publish`.

## 生态包发布

- 库分发沿用项目已有的 NuGet 发布入口 (`dotnet nuget push` 或项目脚本), 不要在 GitHub release job 里内联一套新的发布实现.
- 优先用 NuGet 的受信发布 (OIDC), 需要 API key 时只放在受限的 publish job.
- `Version` / `PackageVersion` 与 tag 严格对齐, 不要把构建版本号或 commit hash 写进包版本.
- GitHub Release 对库分发只出 notes, 不额外上传 `.nupkg`.

## 第三方工具分工

| 工具 | 可以承担 | 必须让给本 skill 的部分 |
| --- | --- | --- |
| dotnet-releaser | 多 RID 打包, 安装器, NuGet 推送 | release notes 正文与 tag 治理 |
| WiX / Inno Setup | Windows 安装器 | 产物命名与变体段, 数量校验 |

安装器属于桌面应用形态, 变体段与安装布局见 desktop-app-skill 与 SKILL.md 的产物命名小节.

## 已知坑

- `GenerateAssemblyInformationalVersionAttribute` 未关闭时, 自己生成的属性会造成重复定义编译错误.
- 单文件发布 (`PublishSingleFile`) 与 NativeAOT 会改变产物结构, 打开后归档内容与冒烟检查方式都要跟着改.
- self-contained 与框架依赖两种产物的命名不同, 混用会让 `PROJECT-VERSION-PLATFORM-ARCH` 规则失效.
- macOS 上的 dmg 与签名公证不在本模块范围, 需要时按 desktop-app-skill 处理.
- 没有锁定文件时 `setup-dotnet` 的缓存基本不命中, 不要为了形式配上缓存.
- `.NET` 相关命令在未安装 SDK 的环境无法验证, 实现后必须在真实 runner 上跑一次完整矩阵, 不要只靠本地读代码判断正确.
