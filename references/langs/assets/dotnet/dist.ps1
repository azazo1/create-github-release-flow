$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 生成当前平台的发布产物 (C# / .NET), 复制到项目 scripts/dist.ps1.
# 需要同时复制 scripts/archive.ps1, scripts/build-version.ps1 与 Directory.Build.props.
#
# 只改下面几个变量:
$ProjectName = "PROJECT"
$ProjectFile = "src/PROJECT/PROJECT.csproj"
$BinaryName = "PROJECT"
$SmokeArgs = @("--version")
$BuildMode = if ($env:BUILD_MODE) { $env:BUILD_MODE } else { "self-contained" }

$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    $arch = $env:TARGET_ARCH
    if (-not $arch) {
        switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
            "X64" { $arch = "x86_64" }
            "Arm64" { $arch = "aarch64" }
            default { throw "无法识别架构, 请显式设置 TARGET_ARCH" }
        }
    }
    $platform = "windows"

    $version = $env:PROJECT_BUILD_VERSION
    if (-not $version) {
        $version = "v$(& 'scripts/build-version.ps1' | Out-String).Trim()"
    }

    Write-Host "构建 $ProjectName $version ($platform-$arch)"

    $staging = "dist/stage"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    $publishArgs = @("publish", $ProjectFile, "-c", "Release", "-o", $staging, "-p:PROJECT_BUILD_VERSION=$version")
    if ($BuildMode -eq "self-contained") {
        $rid = if ($env:RID) { $env:RID } elseif ($arch -eq "aarch64") { "win-arm64" } else { "win-x64" }
        $publishArgs += @("--self-contained", "true", "-r", $rid)
        $binary = "${BinaryName}.exe"
    } else {
        $publishArgs += @("--self-contained", "false")
        $binary = "${BinaryName}.dll"
    }

    & dotnet @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败" }

    # self-contained 是原生可执行文件, 直接运行; 用 dotnet <exe> 会把它当成托管程序集而失败.
    if ($BuildMode -eq "self-contained") {
        $reported = (& "$staging/$binary" @SmokeArgs | Out-String)
    } else {
        $reported = (& dotnet "$staging/$binary" @SmokeArgs | Out-String)
    }
    if ($reported -notmatch [regex]::Escape($version)) {
        throw "版本号校验失败: 期望 $version, 实际输出 $reported"
    }
    Write-Host "版本号校验通过: $version"

    $env:PROJECT_NAME = $ProjectName
    $env:PROJECT_BUILD_VERSION = $version
    if ($BuildMode -eq "self-contained") {
        $env:TARGET_PLATFORM = $platform
        $env:TARGET_ARCH = $arch
        & 'scripts/archive.ps1' -Staging $staging $binary
    } else {
        $env:PLATFORM_INDEPENDENT = "1"
        & 'scripts/archive.ps1' -Staging $staging
    }
    if ($LASTEXITCODE -ne 0) { throw "归档失败" }
} finally {
    Pop-Location
}
