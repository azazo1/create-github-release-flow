$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 生成当前平台的发布产物 (Node.js / TypeScript), 复制到项目 scripts/dist.ps1.
# 需要同时复制 scripts/archive.ps1, scripts/build-version.ps1 与 src/version.ts, 规则与 dist.sh 一致.
#
# 只改下面几个变量:
$ProjectName = "PROJECT"
$Entry = "src/cli.ts"
$BinaryName = "PROJECT"
$SmokeArgs = @("--version")

$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    $platform = "windows"
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

    $binary = "${BinaryName}.exe"
    $staging = "dist/stage"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    bun build $Entry --compile --outfile "$staging/$binary" --define "BUILD_VERSION=`"$version`""
    if ($LASTEXITCODE -ne 0) { throw "打包失败" }

    $reported = (& "$staging/$binary" @SmokeArgs | Out-String)
    if ($reported -notmatch [regex]::Escape($version)) {
        throw "版本号校验失败: 期望 $version, 实际输出 $reported"
    }
    Write-Host "版本号校验通过: $version"

    $env:PROJECT_NAME = $ProjectName
    $env:PROJECT_BUILD_VERSION = $version
    $env:TARGET_PLATFORM = $platform
    $env:TARGET_ARCH = $arch
    & 'scripts/archive.ps1' -Staging $staging $binary
    if ($LASTEXITCODE -ne 0) { throw "归档失败" }
} finally {
    Pop-Location
}
