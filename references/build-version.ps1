$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 复制到项目 scripts/build-version.ps1 后, 通常只需要改 TagPrefix.
# 不要改后面的 tag / dirty 算法.
$TagPrefix = "v"

$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {

function Get-GitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs
    )

    $output = & git @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $text = (($output | Out-String) -replace "`r", "").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

function Select-VersionTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tags
    )

    $lines = $Tags -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    foreach ($line in $lines) {
        # 与 describe 的 --match 保持一致: 设了 TagPrefix 时只接受带前缀的 tag.
        if (-not $TagPrefix -or $line.StartsWith($TagPrefix)) {
            return $line
        }
    }

    return $null
}

# 包版本可能已经带上 tag 前缀 (调用方直接传了 v0.1.0), 统一剥掉, 避免拼出双前缀.
function Normalize-PackageVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ($TagPrefix -and $Version.StartsWith($TagPrefix)) {
        return $Version.Substring($TagPrefix.Length)
    }
    return $Version
}

# 取不到版本 tag 时说明具体原因, 区分"仓库确实没有 tag", "有 tag 但没一个匹配 TagPrefix"
# 和"本地没有 tag 对象 (浅克隆或没 fetch tags)"三种情况.
function Get-MissingTagReason {
    $allTags = Get-GitOutput -GitArgs @("tag", "--list")
    if ($TagPrefix) {
        $matchedTags = Get-GitOutput -GitArgs @("tag", "--list", "$TagPrefix*")
    } else {
        $matchedTags = $allTags
    }

    $firstTag = $null
    if ($allTags) {
        $firstTag = ($allTags -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
    }
    $firstMatched = $null
    if ($matchedTags) {
        $firstMatched = ($matchedTags -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
    }

    $shallow = (Get-GitOutput -GitArgs @("rev-parse", "--is-shallow-repository")) -eq "true"

    if (-not $firstMatched -and $shallow) {
        return "本地是浅克隆, 取不到远端 tag"
    }
    if (-not $firstTag) {
        return "仓库里没有任何 tag"
    }
    if (-not $firstMatched) {
        return "本地 tag 没有一个匹配 TagPrefix=$TagPrefix (现有第一个 tag 是 $firstTag)"
    }
    return "本地有版本 tag ($firstMatched), 但 describe 从 HEAD 取不到它"
}

# 仓库还没有任何版本 tag 时的兜底基础版本号, 由调用方提供.
# 各语言模块给出该生态的结构化 metadata 读取命令, 在 just dist 或 CI 里先算出包版本,
# 再用 PROJECT_PACKAGE_VERSION 传进来.
function Read-PackageVersion {
    $reason = Get-MissingTagReason

    if (-not $env:PROJECT_PACKAGE_VERSION) {
        throw "$reason, 且未提供 PROJECT_PACKAGE_VERSION; 按语言模块给出的结构化命令读出包版本后传给 PROJECT_PACKAGE_VERSION, 或先打一个版本 tag (检查 TagPrefix 前缀, 浅克隆要 fetch tags)"
    }

    $normalized = Normalize-PackageVersion -Version $env:PROJECT_PACKAGE_VERSION
    Write-Warning "$reason; 基础版本号改用包版本 $normalized 加短 hash"
    return $normalized
}

function Get-LatestDescribedTag {
    if ($TagPrefix) {
        return Get-GitOutput -GitArgs @("describe", "--tags", "--abbrev=0", "--match", "$TagPrefix*", "HEAD")
    }
    return Get-GitOutput -GitArgs @("describe", "--tags", "--abbrev=0", "HEAD")
}

function Strip-TagPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Display
    )

    if ($TagPrefix -and $Display.StartsWith($TagPrefix)) {
        return $Display.Substring($TagPrefix.Length)
    }
    return $Display
}

$exactTag = $null
$tags = Get-GitOutput -GitArgs @("tag", "--points-at", "HEAD")
if ($tags) {
    $exactTag = Select-VersionTag -Tags $tags
}

if ($exactTag) {
    $tag = $exactTag
} else {
    $described = Get-LatestDescribedTag
    if ($described) {
        $tag = $described
    } else {
        $tag = "$TagPrefix$(Read-PackageVersion)"
    }
}

$commit = Get-GitOutput -GitArgs @("rev-parse", "--short=7", "HEAD")
$dirty = $false
if ($commit) {
    & git diff-index --quiet HEAD -- | Out-Null
    if ($LASTEXITCODE -eq 1) {
        $dirty = $true
    }
}

if (-not $commit) {
    $display = $tag
} elseif ($dirty) {
    $display = "$tag^$commit"
} elseif ($exactTag) {
    $display = $tag
} else {
    $display = "$tag-$commit"
}

Write-Output (Strip-TagPrefix -Display $display)
} finally {
    Pop-Location
}
