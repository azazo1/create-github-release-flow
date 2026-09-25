# Rust 语言模块

按 SKILL.md 的分派表读取本模块. 这里只写 Rust 的落地方式; 流程, release notes 治理, tag 与 release 规则见 SKILL.md, 语言无关的 YAML 骨架见 [workflow-patterns.md](../workflow-patterns.md).

## 分发形态判定

| 形态 | 判定依据 | 套用规则 |
| --- | --- | --- |
| 二进制/应用 | 有 `[[bin]]` 或 `src/main.rs`, 或项目本身是 Tauri 这类应用 | 运行时版本号显示, 跨平台归档矩阵, SHA256SUMS |
| 库 | 只有 `src/lib.rs`, 用户从 crates.io 获取 | notes-only release, 不打包二进制 |
| 混合 | 同一个 crate 既有 lib 又有 bin | 按用户获取方式分别处理; 库部分不要注入 git 版本号 |

workspace 里要按包判断: `cargo metadata` 列出全部包, 逐个确认谁面向用户.

## 版本来源与 tag 校验

包版本在 `Cargo.toml` 的 `[package].version`, workspace 常用 `[workspace.package].version` 继承. 用结构化 metadata 读取, 不要正则扫清单文件:

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

- workspace 里同一仓库有多个包时, 对每个面向用户的包各读一次, 全部与 tag 对齐.
- 只有 tag 是唯一版本来源的项目 (例如 workspace 里的应用 crate 不发布) 才跳过这一步, 改为只校验 tag 格式与 notes 文件存在.
- 库分发的包版本必须是稳定版本号, 不要把 `git describe` 或短 hash 写进 `Cargo.toml`.

## 版本注入与运行时显示

复制 [assets/rust/build.rs](assets/rust/build.rs) 到项目根, 复制 [assets/rust/version.rs](assets/rust/version.rs) 到 `src/version.rs`, 两者必须配套, 缺少 `build.rs` 时 `env!` 会直接编译失败.

```shell
PROJECT_BUILD_VERSION=v1.2.3 cargo build --release --locked
```

- `build.rs` 只在设置了 `PROJECT_BUILD_VERSION` 时注入, 否则写入 `dev-build`.
- 必须声明 `cargo:rerun-if-env-changed=PROJECT_BUILD_VERSION`, 否则改了环境变量不会重新编译.
- 不要无条件在 `build.rs` 里读 `.git`: 每次 commit 都会让增量编译缓存失效, `target/` 会持续膨胀. 需要 vcs 信息时用 vergen 这类工具, 并且只在发布构建路径打开.
- 库分发的包不要注入构建版本号, 包版本以 metadata 为准.

## 依赖与构建缓存

```yaml
- name: 准备 Rust 工具链
  uses: dtolnay/rust-toolchain@v1
  with:
    toolchain: stable

- name: 恢复构建缓存
  uses: Swatinem/rust-cache@v2
  with:
    workspaces: "."
```

- 构建与测试命令统一加 `--locked`, 让 CI 使用提交过的 `Cargo.lock`.
- `Swatinem/rust-cache` 已覆盖 `target/` 与 registry 缓存, 不要再叠一层 `actions/cache` 缓存同一路径.
- 缓存只是加速: 干净环境必须能完整构建.

## 构建与测试命令

```shell
cargo build --release --locked
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check        # 只报告不修改
```

- 需要额外 target 时用 `rustup target add`, 或让 `dtolnay/rust-toolchain` 的 `targets` 输入安装.
- 交叉编译的产物无法在 runner 上执行, 只能做文件格式检查.

## 平台目标与 runner

| 平台 | 架构 | runner 标签 | target triple | 归档 |
| --- | --- | --- | --- | --- |
| Linux | x86_64 | `ubuntu-24.04` | `x86_64-unknown-linux-gnu` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `aarch64-unknown-linux-gnu` | `.tar.gz` |
| Linux | x86_64 | `ubuntu-24.04` | `x86_64-unknown-linux-musl` | `.tar.gz` |
| Linux | aarch64 | `ubuntu-24.04-arm` | `aarch64-unknown-linux-musl` | `.tar.gz` |
| macOS | x86_64 | `macos-15-intel` | `x86_64-apple-darwin` | `.tar.gz` |
| macOS | aarch64 | `macos-15` | `aarch64-apple-darwin` | `.tar.gz` |
| Windows | x86_64 | `windows-2025` | `x86_64-pc-windows-msvc` | `.zip` |
| Windows | aarch64 | `windows-11-arm` | `aarch64-pc-windows-msvc` | `.zip` |

- 优先用原生 runner 出产物, 交叉编译只在确实没有对应 runner 时使用.
- musl 目标需要额外工具链: 用 `cross` 容器化构建, 或在 runner 上安装 `musl-tools` 与对应 linker.
- `windows-11-arm` 镜像带 `Microsoft.VisualStudio.Component.VC.Tools.ARM64`, 所以 `aarch64-pc-windows-msvc` 可以在该 runner 上原生链接; 仍要在实现时复核 runner 文档.
- 需要静态产物时优先 musl, 不要把 GNU 动态链接产物描述为通用静态二进制.

## 归档与打包

复制 [assets/rust/dist.sh](assets/rust/dist.sh) 到 `scripts/dist.sh`, 同时复制 [../archive.sh](../archive.sh) 与 [../build-version.sh](../build-version.sh); Windows 侧复制 [assets/rust/dist.ps1](assets/rust/dist.ps1), [../archive.ps1](../archive.ps1), [../build-version.ps1](../build-version.ps1).

- `dist.sh` 只改顶部常量: `PROJECT_NAME`, `BINARY_NAME`, `SMOKE_ARGS`.
- 需要交叉编译时设置 `RUST_TARGET`, 并用 `TARGET_PLATFORM` / `TARGET_ARCH` 指定产物命名; 该分支跳过执行, 只做文件格式检查.
- `justfile` 的 `dist` 与 Go 模块给出的形状一致 (单个不接受参数的 recipe, 用平台属性互斥), 只把构建命令换成 `cargo build --release --locked`.
- 归档内容只放二进制, 需要时附加 `README.md` 与 `LICENSE`.

## 生态包发布

- 库分发: 包版本与 tag 严格对齐, 发布入口沿用项目已有的 `cargo publish` 流程或 recipe, 不要在 GitHub release job 里内联一套新的发布实现.
- 不要把构建版本号写进 `Cargo.toml` 的 `version`; 也不要用 `-Z` 之类不稳定特性改包版本.
- workspace 多包发布时逐个确认版本, 一个 tag 对应一组一致的包版本.
- GitHub Release 对库分发只出 notes, 不额外打一份 crate 源码归档.

## 第三方工具分工

| 工具 | 可以承担 | 必须让给本 skill 的部分 |
| --- | --- | --- |
| cargo-dist | 安装器, shell 安装脚本, 归档打包 | release notes 正文, tag 的创建与校验 |
| release-plz | 版本号与依赖的批量升级 PR | tag annotation 与 notes 文件 (它的自动 changelog 只能作为草稿) |
| cross | musl 等交叉编译 | 产物命名与数量校验 |

使用这类工具时固定版本, 并关闭它们自带的 changelog 生成, 否则 release 正文会出现两套来源.

## 已知坑

- `build.rs` 无条件读 `.git` 会让 `target/` 每次 commit 都重编, 增量缓存形同虚设.
- 忘记 `cargo:rerun-if-env-changed` 时, 版本号改了却不重编, 产物里还是旧版本.
- 少了 `--locked` 时 CI 可能悄悄升级依赖, 与本地结果不一致.
- `macos-15` 是 arm64, `macos-15-intel` 才是 x86_64; `macos-14` 已进入 deprecated.
- musl 目标下的 OpenSSL 之类原生依赖需要 vendored 特性或额外 sysroot, 只加 target 往往构建失败.
- 交叉编译产物不能执行, 冒烟检查要改成文件格式检查, 并在报告里说明该平台未真实运行.
