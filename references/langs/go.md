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

仓库还没有版本 tag 时没有包版本可读, `build-version.py` 只能用占位版本: `dist.py` 顶部的 `PACKAGE_VERSION` 常量与 CI 的 `解析构建版本` 步骤都传 `0.0.0`, 得到 `0.0.0-<短 hash>` 这样的兜底版本号, 于是 branch 与 PR 运行不会因为缺版本号失败. 首个 tag 推送后正式版本由 tag 提供, 不要在项目里长期维护这份占位版本号.

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
- `dist.py` 的平台与架构取自 `go env GOOS` / `GOARCH`, 与 `go build` 实际目标一致, 所以不要用 `TARGET_PLATFORM` / `TARGET_ARCH` 另设命名, 否则产物名会与实际文件格式不符.
- `version` 变量必须是变量而不是常量, 常量无法在链接期覆盖.
- 日常开发构建不设置 `PROJECT_BUILD_VERSION`, 显示 `dev-build`.
- `just dist` 与 CI 都传带 `v` 前缀的值 (二进制内显示跟随 tag 样式); 产物名里的 `v` 由 `dist.py` 剥掉, 调用方不用管.
- 不要用 `debug.ReadBuildInfo()` 的 vcs 信息拼版本号: `-buildvcs=false` 或非 git 构建时它缺失, 而且会把哈希带进正式产物.
- 注入失效时 `-X` 不报错, 所以构建后必须冒烟断言一次.

```yaml
- name: 生成当前平台发布产物
  env:
    PROJECT_BUILD_VERSION: v${{ needs.version.outputs.build_version }}
  run: uv run --no-project python scripts/dist.py
```

- 用 `uv run --no-project python` 而不是裸 `python` / `python3`: 解释器名在各平台不一致, uv 会自己选一个可用的, 三个平台共用同一条命令. Go 项目的脚本不碰项目环境, 所以带 `--no-project`.
- 该步骤所在 job 需要先执行 `准备 uv` (见 [workflow-patterns.md](../workflow-patterns.md#ci-tag-与手动条件)).

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
- 矩阵覆盖 Windows 时测试本身也要跨平台: 不要依赖 Unix 语义, 例如 `HOME` (Windows 的 `os.UserHomeDir()` 读 `USERPROFILE`) 与硬编码的 `/tmp` (会被解析成当前盘符). 路径断言优先用 `t.TempDir()` 与 `filepath.Join`.

## 平台目标与 runner

分两种做法, 先判定再选:

- **纯 Go 且无 cgo**: 在一个 runner 上交叉编译出全部目标, 构建 job 不用矩阵. 这是默认选择, 六个目标通常几十秒就能出完.
- **含 cgo**: 产物会绑定构建机的系统库, 交叉编译出来的东西在目标平台可能跑不起来, 按原生 runner 矩阵构建.

判定命令, 输出为空才说明整条依赖链没有 cgo:

```shell
go list -deps -f '{{if .CgoFiles}}{{.ImportPath}}{{end}}' ./cmd/PROJECT
```

`CGO_ENABLED=0` 要显式固定. 注意它只是关掉 cgo 编译, 不能把本来必须 cgo 的项目变成纯 Go: 依赖链里一旦有 `net`, `os/user` 这类会根据 cgo 切换实现的包, 关掉之后行为会变化, 因此以 `go list` 的结果为准, 不要只看 `CGO_ENABLED` 有没有设置.

原生矩阵用的 runner 标签与 `GOOS`/`GOARCH` 对应关系 (交叉编译时右侧两列照样可用, 只是不需要对应 runner):

| 平台 | 架构 | runner 标签 | `GOOS`/`GOARCH` | 归档 |
| --- | --- | --- | --- | --- |
| Linux | x86_64 | `ubuntu-24.04` | `linux`/`amd64` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `linux`/`arm64` | `.tar.gz` |
| macOS | x86_64 | `macos-15-intel` | `darwin`/`amd64` | `.tar.gz` |
| macOS | aarch64 | `macos-15` | `darwin`/`arm64` | `.tar.gz` |
| Windows | x86_64 | `windows-2025` | `windows`/`amd64` | `.zip` |
| Windows | aarch64 | `windows-11-arm` | `windows`/`arm64` | `.zip` |

- 原生矩阵: 可以真正执行产物, `--version` 冒烟检查最有力; 该标签组合已在真实仓库 (dida-cli) 全绿, 但 runner 资格, 镜像漂移与平台依赖只能在真实 run 上确认, 见 [pending-verification.md](../pending-verification.md).
- 交叉编译: 跑不了非宿主平台的产物, 校验退化为归档条目数, 文件头, 架构与注入的版本串, 见下文.
- 归档名里的平台与架构 token 用 `macos`, `x86_64`, `aarch64` 这类通用写法, 不要把 `darwin` 与 `arm64` 直接写进产物名.

交叉编译的全部目标 (单 runner, 无矩阵):

```yaml
- name: 生成全部平台发布产物
  env:
    PROJECT_BUILD_VERSION: v${{ needs.version.outputs.build_version }}
  run: uv run --no-project python scripts/dist.py --all

- name: 运行宿主平台 smoke test
  shell: bash
  run: |
    set -euo pipefail
    # 只有宿主平台这一份能真正执行, 其余靠 dist.py 的架构与版本串校验.
    # 路径必须指向该目标自己的 staging 目录, 不能用共用的单一路径.
    actual="$(./dist/stage/linux-x86_64/PROJECT --version)"
    expected="v${{ needs.version.outputs.build_version }}"
    if [[ "$actual" != "$expected" ]]; then
      echo "版本输出为 $actual, 预期为 $expected" >&2
      exit 1
    fi
```

测试仍然按操作系统各跑一遍, 不能因为构建能交叉就只跑一份:

```yaml
strategy:
  fail-fast: false
  matrix:
    os: [ubuntu-24.04, windows-2025, macos-15]
```

原生矩阵 (含 cgo 或需要真机冒烟时):

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

复制 [assets/go/dist.py](assets/go/dist.py) 到项目的 `scripts/dist.py`, 同时复制 [../archive.py](../archive.py), [../build-version.py](../build-version.py) 与 [../release_common.py](../release_common.py). 平台判断在脚本内部完成, 不需要再准备一份 Windows 专用脚本.

`dist.py` 只改顶部几个常量: `PROJECT_NAME`, `MAIN_PACKAGE`, `BINARY_NAME`, `PACKAGE_VERSION`, `SMOKE_ARGS`. 它负责构建, 冒烟断言版本号, 然后交给 `archive.py` 拼名字并压缩. 归档用的版本段已在脚本内部剥掉 `v` 前缀, 所以产物名形如 `dida-0.1.2-linux-x86_64.tar.gz`, 而二进制内显示的是 `v0.1.2`; 两者样式不同是刻意的, 不要为了统一去改这段逻辑.

`dist.py` 支持两种调用:

- 不带参数: 只构建 `go env GOOS` / `GOARCH` 对应的当前平台, 并真的执行一次 `--version` 冒烟.
- `--all`: 遍历 `DEFAULT_TARGETS` 的全部六个目标, 逐个设置 `GOOS` / `GOARCH` 交叉编译. 非宿主平台的产物跑不起来, 因此改为校验归档条目, 文件头, 架构与二进制里的版本串. 这条路径要先确认依赖链没有 cgo, 脚本本身不替你判断.

`justfile` 保持一个不接受参数的 `dist`, 平台差异交给脚本:

```justfile
# 根据当前平台生成发布产物.
dist:
    uv run --no-project python scripts/dist.py
```

需要一条命令出全部平台时, 由 CI 直接调 `scripts/dist.py --all`, 不要给 recipe 加参数.

不经 `just dist` 直接跑 `scripts/dist.py` 时, 仓库还没有 tag 的情况下脚本会用 `PACKAGE_VERSION` 常量兜底, 不用在外面再传变量.

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

- `-X` 路径写错或变量被改成常量时静默失效, 必须靠 `dist.py` 的冒烟断言兜住.
- 默认的 buildvcs 会把 git 状态写进二进制, 发布构建加 `-trimpath`, 并显式决定是否需要 vcs 信息.
- `CGO_ENABLED=0` 得到静态产物, 不继承 runner 的 glibc 下限; 它也是单 runner 交叉编译成立的前提. 一旦打开 cgo, 就要按 SKILL.md 的 glibc 说明评估兼容性, 不要声称普通动态链接产物是通用静态二进制, 也回到原生矩阵去构建.
- 交叉编译时 `GOOS` / `GOARCH` 必须同时进 `go build` 的环境与产物命名, 两处不一致会产出"名字是 linux 内容是 darwin"的归档; 命名 token 要跟着实际构建目标走, 不要用 `go env` 的默认值覆盖它.
- 交叉编译的产物在本机跑不起来, 别把宿主平台的 `--version` 结果当成全部产物的验证; 其余平台要么查文件头与架构, 要么干脆按原生矩阵构建.
- 交叉编译多个目标时, 每个目标必须有自己的 staging 路径 (`dist/stage/<platform>-<arch>/`). 六个目标共用一个输出路径时, 后一个会覆盖前一个, 最后留下的那份往往是别的平台, 于是后续的 `--version` smoke test 直接报 `cannot execute binary file: Exec format error` (实测踩到: 最后一个目标是 macOS arm64, 在 Linux runner 上执行).
- Windows 产物要带 `.exe` 后缀并打 `zip`, 命名仍用 `windows` 与 `x86_64` 这样的 token.
- `macos-15` 是 arm64, `macos-15-intel` 才是 x86_64; `macos-latest` 现在是 macOS 26 arm64, `ubuntu-latest` 是 x64, 不要靠 `*-latest` 猜架构.
- 构建期不要读取 `.git`: Go 的 `-buildvcs` 与自定义版本注入都会让构建结果随 commit 变化, 增量缓存跟着失效.
- Windows runner 上跑 `gofmt -l .` 之前必须让仓库统一 LF 行尾: Git for Windows 默认 `core.autocrlf=true`, 检出时会把文本文件转成 CRLF, 于是 gofmt 把所有 `.go` 文件都判为未格式化 (实测整个仓库全被列出). 在 `.gitattributes` 里声明 `* text=auto eol=lf` 即可解决, 不要用"Windows 上跳过格式检查"来回避.
