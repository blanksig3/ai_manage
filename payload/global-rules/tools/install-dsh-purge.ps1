[CmdletBinding()]
param(
    [string]$Profile = 'dsh-tui',
    [string]$PackageName = 'dsh-purge-community',
    [string]$TarballUrl = 'https://github.com/kingcharleslzy-ai/dsh-purge/releases/latest/download/dsh-purge-community.tgz',
    [string]$TarballPath = '',
    [string]$UserHome = $env:USERPROFILE,
    [string]$DshHome = '',
    [switch]$SkipInstall,
    [switch]$SkipApply,
    [switch]$DryRun,
    [switch]$Quiet
)

# DeepSeek (DSH) 的默认增强：安装 dsh-purge 插件、固定实例路径、应用宿主补丁。
# 幂等：已装且已固定时只读不写。返回对象由调用方决定是否中断；本脚本不调用 exit。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Write-Info([string]$Text) { if (-not $Quiet) { Write-Host "    $Text" -ForegroundColor Gray } }
function Write-Ok([string]$Text) { if (-not $Quiet) { Write-Host "    $Text" -ForegroundColor Green } }
function Write-Warn([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

function Get-NpmPrefix {
    $npm = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npm) {
        try {
            $raw = (& $npm.Source prefix -g 2>$null | Out-String).Trim()
            $line = @($raw -split '\r?\n' | Where-Object { $_.Trim() })[-1]
            if ($line -and (Test-Path -LiteralPath $line.Trim() -PathType Container)) { return $line.Trim() }
        } catch {}
    }
    $fallback = Join-Path $env:APPDATA 'npm'
    if (Test-Path -LiteralPath $fallback -PathType Container) { return $fallback }
    return ''
}

function Resolve-AiBase([string]$Prefix) {
    if (-not $Prefix) { return '' }
    $candidates = @(
        (Join-Path $Prefix 'node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai'),
        (Join-Path $Prefix 'node_modules\@deepseek-ai')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'dsh-agent-instructions\lib') -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return ''
}

function Get-DshCli([string]$Prefix) {
    if ($Prefix) {
        foreach ($name in @('dsh.cmd', 'dsh.exe')) {
            $path = Join-Path $Prefix $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
    }
    $cmd = Get-Command dsh.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return ''
}

function Get-NodeExe {
    $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($node) { return $node.Source }
    foreach ($candidate in @((Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-PluginVersion([string]$PackageJson) {
    if (-not (Test-Path -LiteralPath $PackageJson -PathType Leaf)) { return '' }
    try { return [string]([IO.File]::ReadAllText($PackageJson, [Text.Encoding]::UTF8) | ConvertFrom-Json).version } catch { return '' }
}

function Find-LocalTarball([string]$Root) {
    $cache = Join-Path $Root 'dsh-purge-community\pkgs'
    if (-not (Test-Path -LiteralPath $cache -PathType Container)) { return '' }
    $tgz = Get-ChildItem -LiteralPath $cache -Recurse -File -Filter "$PackageName-*.tgz" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($tgz) { return $tgz.FullName }
    return ''
}

$dshRoot = if ($DshHome) { $DshHome } else { $env:DSH_HOME }
if (-not $dshRoot) { $dshRoot = Join-Path $UserHome '.dsh' }
$profileDir = Join-Path $dshRoot ('profiles\' + $Profile)
$packageJson = Join-Path $profileDir ('node_modules\' + $PackageName + '\package.json')
$prefix = Get-NpmPrefix
$aiBase = Resolve-AiBase $prefix
$dshCli = Get-DshCli $prefix
$nodeExe = Get-NodeExe

$result = [pscustomobject]@{
    ok = $false
    status = 'unknown'
    package = $PackageName
    version = ''
    profile = $Profile
    profileDir = $profileDir
    aiBase = $aiBase
    dshHome = $dshRoot
    pinned = $false
    applied = $false
    detail = ''
}

$version = Get-PluginVersion $packageJson
if ($version) {
    Write-Ok ("dsh-purge 已安装：{0} {1}" -f $PackageName, $version)
} elseif ($SkipInstall) {
    Write-Warn '跳过 dsh-purge 安装（-SkipInstall）。'
    $result.status = 'skip-install'
    return $result
} else {
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        Write-Warn ("profile 目录尚未创建：{0}；先启动一次 DeepSeek (DSH)，下次进入会自动补齐 dsh-purge。" -f $profileDir)
        $result.status = 'pending-profile'
        $result.detail = 'profile-missing'
        return $result
    }
    $source = ''
    if ($TarballPath) {
        if (-not (Test-Path -LiteralPath $TarballPath -PathType Leaf)) { throw "指定的安装包不存在：$TarballPath" }
        $source = (Resolve-Path -LiteralPath $TarballPath).Path
    } else {
        $source = Find-LocalTarball $dshRoot
        if (-not $source) { $source = $TarballUrl }
    }
    if (-not $dshCli) { throw '未找到 dsh CLI（npm 全局安装的 dsh.cmd），无法安装 dsh-purge。' }
    Write-Info ("安装源：{0}" -f $source)
    if ($DryRun) {
        Write-Info ("[DryRun] {0} plugin --profile {1} add {2}" -f $dshCli, $Profile, $source)
    } else {
        & $dshCli plugin --profile $Profile add $source
        if ($LASTEXITCODE -ne 0) { throw "dsh plugin add 失败（退出码 $LASTEXITCODE）。检查网络、代理或 npm 后重试。" }
        $version = Get-PluginVersion $packageJson
        if (-not $version) { throw "安装后仍未找到 $packageJson；请查看 dsh 的输出。" }
        Write-Ok ("已安装 dsh-purge：{0}" -f $version)
    }
}

$pins = [ordered]@{ DSH_BASE = $aiBase; PURGE_PROFILE_DIR = $profileDir; DSH_PROFILE = $Profile }
$pinMiss = 0
foreach ($key in $pins.Keys) {
    $value = [string]$pins[$key]
    if (-not $value) { continue }
    $current = [Environment]::GetEnvironmentVariable($key, 'User')
    if ($current -ne $value) {
        if ($DryRun) { Write-Info ("[DryRun] set {0}={1}" -f $key, $value) }
        else { [Environment]::SetEnvironmentVariable($key, $value, 'User'); Write-Ok ("固定 {0}={1}" -f $key, $value) }
        $pinMiss++
    }
}
$result.pinned = ($pinMiss -eq 0)
if ($pinMiss -eq 0) { Write-Info '实例路径已固定（DSH_BASE / PURGE_PROFILE_DIR / DSH_PROFILE）。' }

if ($SkipApply) {
    Write-Warn '跳过 dsh-purge 补丁应用（-SkipApply）。'
    $result.status = 'installed'
    $result.version = $version
    $result.detail = 'skip-apply'
    return $result
}
if (-not $aiBase) {
    Write-Warn '未定位到宿主的 @deepseek-ai 目录；插件已安装，但没有应用补丁。'
    $result.status = 'installed'
    $result.version = $version
    $result.detail = 'ai-base-missing'
    return $result
}
if (-not $nodeExe) {
    Write-Warn '未找到 node.exe；插件已安装，但没有应用补丁。'
    $result.status = 'installed'
    $result.version = $version
    $result.detail = 'node-missing'
    return $result
}

$engine = Join-Path $profileDir ('node_modules\' + $PackageName + '\bin\community.js')
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
    Write-Warn ("缺少 dsh-purge 入口：{0}" -f $engine)
    $result.status = 'installed'
    $result.version = $version
    $result.detail = 'engine-missing'
    return $result
}

if ($DryRun) {
    Write-Info ("[DryRun] {0} {1} apply" -f $nodeExe, $engine)
    $result.status = 'dry-run'
    $result.version = $version
    $result.detail = 'dry-run'
    return $result
}

Write-Info '应用宿主补丁（提示词层 + 代码默认 + 引擎级开关）……'
$env:DSH_HOME = $dshRoot
$env:DSH_BASE = $aiBase
$env:PURGE_PROFILE_DIR = $profileDir
$env:DSH_PROFILE = $Profile
$applyOutput = & $nodeExe $engine apply 2>&1
$applyCode = $LASTEXITCODE
foreach ($line in @($applyOutput)) { if ("$line".Trim()) { Write-Info ("  " + "$line".Trim()) } }

$result.version = $version
$result.applied = ($applyCode -eq 0)
$result.ok = ($applyCode -eq 0)
$result.status = if ($applyCode -eq 0) { 'applied' } else { 'apply-failed' }
$result.detail = "apply exit=$applyCode"
if ($applyCode -eq 0) {
    Write-Ok 'dsh-purge 已启用；重启 DeepSeek (DSH) 后完全生效。'
} else {
    Write-Warn ("dsh-purge apply 退出码 {0}；插件已安装，可在面板里手动点「应用」。" -f $applyCode)
}
return $result
