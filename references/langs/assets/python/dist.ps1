$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 生成当前平台的发布产物 (Python 二进制形态), 复制到项目 scripts/dist.ps1.
# 需要同时复制 scripts/archive.ps1, scripts/build-version.ps1 与 _build_version.py.
# Windows 侧只支持 pyinstaller, 规则与 dist.sh 的 pyinstaller 分支一致.
#
# 只改下面几个变量:
$ProjectName = "PROJECT"
$PackageDir = "src/PROJECT"
# PyInstaller 的入口必须是绝对导入的启动脚本, 不能用包内的 __main__.py:
# 后者被当作顶层 __main__ 执行时相对导入会失败. 复制 assets/python/entry.py 到 scripts/.
$Entry = "scripts/entry.py"
# 包所在的那一层目录, 供 PyInstaller 解析绝对导入.
$PackagePath = if ($env:PACKAGE_PATH) { $env:PACKAGE_PATH } else { "src" }
$BinaryName = "PROJECT"
$SmokeArgs = @("--version")
$Python = if ($env:PYTHON) { $env:PYTHON } else { "python" }

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

    $staging = "dist/stage"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    Set-Content -LiteralPath "$PackageDir/_generated_version.py" -Value "BUILD_VERSION = `"$version`""

    & $Python -m PyInstaller --onefile --clean --name $BinaryName --paths $PackagePath --distpath $staging --workpath "dist/pyinstaller/build" --specpath "dist/pyinstaller" $Entry
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller 构建失败" }

    $binary = "${BinaryName}.exe"
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
