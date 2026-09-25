$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 生成当前平台的发布产物 (Rust), 复制到项目 scripts/dist.ps1.
# 需要同时复制 scripts/archive.ps1, scripts/build-version.ps1 与 build.rs, 规则与 dist.sh 一致.
#
# 只改下面几个变量:
$ProjectName = "PROJECT"
$BinaryName = "PROJECT"
$SmokeArgs = @("--version")

$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    $platform = if ($env:TARGET_PLATFORM) { $env:TARGET_PLATFORM } else { "windows" }
    $arch = $env:TARGET_ARCH
    if (-not $arch) {
        switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
            "X64" { $arch = "x86_64" }
            "Arm64" { $arch = "aarch64" }
            default { throw "无法识别架构, 请显式设置 TARGET_ARCH" }
        }
    }

    $version = $env:PROJECT_BUILD_VERSION
    if (-not $version) {
        $version = "v$(& 'scripts/build-version.ps1' | Out-String).Trim()"
    }

    Write-Host "构建 $ProjectName $version ($platform-$arch)"

    $cargoArgs = @("build", "--release", "--locked")
    if ($env:RUST_TARGET) { $cargoArgs += @("--target", $env:RUST_TARGET) }
    & cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) { throw "cargo build 失败" }

    $binary = "${BinaryName}.exe"
    $buildDir = "target/release"
    if ($env:RUST_TARGET) { $buildDir = "target/$($env:RUST_TARGET)/release" }

    $staging = "dist/stage"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Copy-Item -LiteralPath "$buildDir/$binary" -Destination "$staging/$binary"

    if ($env:RUST_TARGET) {
        Write-Host "交叉编译产物无法本机执行, 只检查文件格式"
        $bytes = [System.IO.File]::ReadAllBytes("$staging/$binary")
        if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
            throw "PE 文件头无效: $staging/$binary"
        }
    } else {
        $reported = (& "$staging/$binary" @SmokeArgs | Out-String)
        if ($reported -notmatch [regex]::Escape($version)) {
            throw "版本号校验失败: 期望 $version, 实际输出 $reported"
        }
        Write-Host "版本号校验通过: $version"
    }

    $env:PROJECT_NAME = $ProjectName
    $env:PROJECT_BUILD_VERSION = $version
    $env:TARGET_PLATFORM = $platform
    $env:TARGET_ARCH = $arch
    & 'scripts/archive.ps1' -Staging $staging $binary
    if ($LASTEXITCODE -ne 0) { throw "归档失败" }
} finally {
    Pop-Location
}
