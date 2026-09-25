# Go 语言模块

按 SKILL.md 的分派表读取本模块. 这里只写 Go 的落地方式; 流程, release notes 治理, tag 与 release 规则见 SKILL.md, 语言无关的 YAML 骨架见 [workflow-patterns.md](../workflow-patterns.md).

## 分发形态判定

| 形态 | 判定依据 | 套用规则 |
| --- | --- | --- |
| 二进制/应用 | 存在 `package main`, 通常放在 `cmd/<name>` | 运行时版本号显示, 跨平台归档矩阵, SHA256SUMS |
| 库 | 只有可导入的包, 没有 `main` | notes-only release, 不打包二进制 |
| 混合 | 同一仓库既有 `cmd/` 又有可导入包 | 按用户实际获取方式分别处理, 二进制部分仍出归档 |

`go.mod` 里出现 `main` 包不代表用户会下载二进制; 判断以用户获取方式为准.

## 版本来源与 tag 校验

`go.mod` 不保存版本号, tag 是唯一版本来源, 不要新增第二份版本状态, 也不要用 `//go:generate` 之类机制往文件里写版本.

校验步骤只做两件事:

- tag 必须以项目约定的前缀开头 (通常 `v`).
- `docs/changelog/<version>.md` 存在且非空.

主版本号大于等于 2 时, `go.mod` 的 module path 必须以 `/v2` 这类后缀结尾, 并且 tag 写作 `v2.x.y`, 否则 `go get` 无法解析.

```yaml
- name: 校验发布版本
  id: release_version
  if: steps.release_context.outputs.is_release == 'true'
  env:
    TAG_NAME: ${{ steps.release_context.outputs.tag_name }}
  shell: bash
  run: |
    set -euo pipefail
    if [[ "$TAG_NAME" != v* ]]; then
      echo "发布 tag 必须以 v 开头: $TAG_NAME" >&2
      exit 1
    fi

    version="${TAG_NAME#v}"
    manual_notes="docs/changelog/$version.md"
    if [[ ! -s "$manual_notes" ]]; then
      echo "缺少 release notes: $manual_notes" >&2
      exit 1
    fi

    echo "version=$version" >> "$GITHUB_OUTPUT"
```

## 版本注入与运行时显示

复制 [assets/go/version.go](assets/go/version.go) 到项目的 `internal/buildinfo/version.go`, 它是被注入的落点. 注入只在发布构建路径发生:

```shell
go build -trimpath \
  -ldflags "-s -w -X $(go list -m)/internal/buildinfo.version=$PROJECT_BUILD_VERSION" \
  -o dist/stage/dida ./cmd/dida
```

- 注入路径是完整的包导入路径, 用 `go list -m` 取模块名, 不要手写, 重命名模块时会静默失效.
- `version` 变量必须是变量而不是常量, 常量无法在链接期覆盖.
- 日常开发构建不设置 `PROJECT_BUILD_VERSION`, 显示 `dev-build`.
- 不要用 `debug.ReadBuildInfo()` 的 vcs 信息拼版本号: `-buildvcs=false` 或非 git 构建时它缺失, 而且会把哈希带进正式产物.
- 注入失效时 `-X` 不报错, 所以构建后必须冒烟断言一次.

```yaml
- name: 生成当前平台发布产物
  shell: bash
  env:
    PROJECT_BUILD_VERSION: v${{ needs.version.outputs.build_version }}
  run: bash scripts/dist.sh
```

## 依赖与构建缓存

使用 `actions/setup-go` 的内置缓存, 它缓存 `GOMODCACHE` 与构建缓存, 不需要再叠一层 `actions/cache`:

```yaml
- name: 准备 Go
  uses: actions/setup-go@v7
  with:
    go-version-file: go.mod
    cache: true
```

- `go-version-file` 跟随 `go.mod`, 不要在 workflow 里另写死一个 Go 版本.
- 不要缓存 `bin/` 或 `dist/`; 发布产物必须由 artifact 汇总, 不能依赖缓存.
- 私有模块需要 `GOPRIVATE` 与凭据时, 只放在低权限构建 job, 不要进 release job.

## 构建与测试命令

```shell
go build ./...
go vet ./...
go test ./... -count=1
gofmt -l .          # 只报告不修改
```

- lockfile 是 `go.sum`, 依赖整理用 `go mod tidy` 并提交结果.
- 需要额外静态检查时固定工具版本 (例如 `go install honnef.co/go/tools/cmd/staticcheck@<version>`), 不要用浮动版本.
- CI 里的格式检查必须只报告, 不要自动改写工作区.

## 平台目标与 runner

| 平台 | 架构 | runner 标签 | `GOOS`/`GOARCH` | 归档 |
| --- | --- | --- | --- | --- |
| Linux | x86_64 | `ubuntu-24.04` | `linux`/`amd64` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `linux`/`arm64` | `.tar.gz` |
| macOS | x86_64 | `macos-15-intel` | `darwin`/`amd64` | `.tar.gz` |
| macOS | aarch64 | `macos-15` | `darwin`/`arm64` | `.tar.gz` |
| Windows | x86_64 | `windows-2025` | `windows`/`amd64` | `.zip` |
| Windows | aarch64 | `windows-11-arm` | `windows`/`arm64` | `.zip` |

- 用原生 runner 而不是交叉编译: 冒烟检查要真正执行产物, 交叉编译的产物在 runner 上跑不起来. Go 交叉编译本身很容易, 但只能做文件格式检查.
- 该标签组合已在真实仓库 (dida-cli) 全绿, 仍然要在实现时按 SKILL.md 要求复核 runner 文档.
- 归档名里的平台与架构 token 用 `macos`, `x86_64`, `aarch64` 这类通用写法, 不要把 `darwin` 与 `arm64` 直接写进产物名.

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - runner: ubuntu-24.04
        platform: linux
        arch: x86_64
      - runner: ubuntu-24.04-arm
        platform: linux
        arch: aarch64
      - runner: macos-15-intel
        platform: macos
        arch: x86_64
      - runner: macos-15
        platform: macos
        arch: aarch64
      - runner: windows-2025
        platform: windows
        arch: x86_64
      - runner: windows-11-arm
        platform: windows
        arch: aarch64
```

## 归档与打包

复制 [assets/go/dist.sh](assets/go/dist.sh) 到项目的 `scripts/dist.sh`, 同时复制 [../archive.sh](../archive.sh) 与 [../build-version.sh](../build-version.sh); Windows 侧对应复制 [assets/go/dist.ps1](assets/go/dist.ps1), [../archive.ps1](../archive.ps1), [../build-version.ps1](../build-version.ps1).

`dist.sh` 只改顶部几个常量: `PROJECT_NAME`, `MAIN_PACKAGE`, `BINARY_NAME`, `SMOKE_ARGS`. 它负责构建, 冒烟断言版本号, 然后交给 `archive.sh` 拼名字并压缩.

`justfile` 保持一个不接受参数的 `dist`:

```justfile
# 根据当前平台生成发布产物.
[macos]
dist:
    PROJECT_BUILD_VERSION="v$(bash scripts/build-version.sh)" bash scripts/dist.sh

# 根据当前平台生成发布产物.
[linux]
dist:
    PROJECT_BUILD_VERSION="v$(bash scripts/build-version.sh)" bash scripts/dist.sh

# 根据当前平台生成发布产物.
[windows]
[script('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')]
dist:
    $ErrorActionPreference = 'Stop'
    $env:PROJECT_BUILD_VERSION = "v$(& 'scripts/build-version.ps1' | Out-String).Trim()"
    & 'scripts/dist.ps1'
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
```

归档内容只放二进制本身, 需要时附加 `README.md` 与 `LICENSE`, 不要塞入 `go.mod` 或源码.

## 生态包发布

- 库分发不需要上传任何包仓库: 消费者用 `go get <module>@vX.Y.Z`, GitHub Release 只出 notes.
- 不要为 Go module 另打一份源码归档, 一个 `zip` 归档就够; `SHA256SUMS` 也只对二进制产物生成.
- 不要为了对齐版本号去改 `go.mod`: 它没有版本字段, 版本完全由 tag 表达.
- 想让模块出现在 pkg.go.dev, 只需公开仓库加正式 tag; 发布产物不要把 `vendor/` 打进去.

## 第三方工具分工

goreleaser 可以承担 deb/rpm, Homebrew tap, scoop 这类分发产物, 但必须满足:

- 固定版本, 并用 `goreleaser/goreleaser-action` 下载预编译二进制; 不要用 `go install` 装它, 那会把工具自身的 Go 版本要求带进项目 (实测踩坑: 某个 goreleaser 版本要求 Go 1.25.1 而项目 `go.mod` 是 1.24).
- 配置里关闭自动 changelog 生成, release notes 只用 `docs/changelog/VERSION.md`.
- 归档来源要单一: 矩阵 job 出归档时, 就不要让 goreleaser 再出一份同名归档, 否则数量校验与 `SHA256SUMS` 会重复计数.
- goreleaser 在低权限 job 里跑, 只有 release job 拿 `contents: write`.

## 已知坑

- `-X` 路径写错或变量被改成常量时静默失效, 必须靠 `dist.sh` 的冒烟断言兜住.
- 默认的 buildvcs 会把 git 状态写进二进制, 发布构建加 `-trimpath`, 并显式决定是否需要 vcs 信息.
- `CGO_ENABLED=0` 得到静态产物, 不继承 runner 的 glibc 下限; 一旦打开 cgo, 就要按 SKILL.md 的 glibc 说明评估兼容性, 不要声称普通动态链接产物是通用静态二进制.
- Windows 产物要带 `.exe` 后缀并打 `zip`, 命名仍用 `windows` 与 `x86_64` 这样的 token.
- `macos-15` 是 arm64, `macos-15-intel` 才是 x86_64; `macos-latest` 现在是 macOS 26 arm64, `ubuntu-latest` 是 x64, 不要靠 `*-latest` 猜架构.
- 构建期不要读取 `.git`: Go 的 `-buildvcs` 与自定义版本注入都会让构建结果随 commit 变化, 增量缓存跟着失效.
