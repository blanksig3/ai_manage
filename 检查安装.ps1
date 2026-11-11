[CmdletBinding()]
param(
    [string]$UserHome = $env:USERPROFILE,
    [string]$TestRoot = '',
    [switch]$SkipRegistry
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$PackageId = 'ai-global-rules-context-launcher-v1'
$ManagedBegin = '<!-- AI-GLOBAL-RULES:BEGIN -->'
$ManagedEnd = '<!-- AI-GLOBAL-RULES:END -->'
$script:Failures = New-Object 'Collections.Generic.List[string]'

function Get-FullPath([string]$Path) { return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\') }
function Assert-ChildPath([string]$Child, [string]$Parent, [string]$Name) {
    $childFull = (Get-FullPath $Child) + '\'
    $parentFull = (Get-FullPath $Parent) + '\'
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name 超出用户目录：$Child" }
}
function Assert-SamePath([string]$Actual, [string]$Expected, [string]$Name) {
    if ((Get-FullPath $Actual) -ine (Get-FullPath $Expected)) { throw "$Name 路径不匹配：$Actual" }
}
function Pass([string]$Text) { Write-Host "[PASS] $Text" -ForegroundColor Green }
function Fail([string]$Text) { Write-Host "[FAIL] $Text" -ForegroundColor Red; $script:Failures.Add($Text) }
function Test-ManagedEntry([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "入口缺失：$Path"; return }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $begin = [regex]::Matches($text, [regex]::Escape($ManagedBegin)).Count
    $end = [regex]::Matches($text, [regex]::Escape($ManagedEnd)).Count
    if ($begin -ne 1 -or $end -ne 1) { Fail "入口受管块数量不正确：$Path"; return }
    if ($text -notlike "*$Expected*") { Fail "入口未指向安装规则：$Path"; return }
    Pass "入口受管块：$Path"
}
function Test-InstalledManifest([string]$Root) {
    $manifest = Join-Path $Root '.installed-manifest.sha256'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Fail '规则安装清单缺失'; return }
    $count = 0
    foreach ($line in [IO.File]::ReadAllLines($manifest, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { Fail "规则清单格式错误：$line"; return }
        $path = Join-Path $Root ($Matches[2].Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "规则文件缺失：$($Matches[2])"; return }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $Matches[1]) { Fail "规则文件被改动：$($Matches[2])"; return }
        $count++
    }
    Pass "规则安装清单（$count 个文件）"
}

if ($TestRoot) {
    $UserHome = Join-Path (Get-FullPath $TestRoot) 'User'
    $SkipRegistry = $true
}
$UserHome = Get-FullPath $UserHome
$statePath = Join-Path $UserHome '.ai-global-rules-install.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Fail "安装状态缺失：$statePath"
    exit 1
}
$state = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if ($state.packageId -ne $PackageId) { Fail '安装状态 packageId 不匹配'; exit 1 }
try {
    Assert-SamePath ([string]$state.userHome) $UserHome 'userHome'
    Assert-ChildPath ([string]$state.rulesDir) $UserHome 'rulesDir'
    Assert-ChildPath ([string]$state.launcherDir) $UserHome 'launcherDir'
    Assert-SamePath ([string]$state.pickerPath) (Join-Path ([string]$state.launcherDir) 'ai-picker.ps1') 'pickerPath'
    Assert-SamePath ([string]$state.configPath) (Join-Path ([string]$state.launcherDir) 'ai-tools.json') 'configPath'
    Assert-SamePath ([string]$state.claudeEntry) (Join-Path $UserHome '.claude\CLAUDE.md') 'claudeEntry'
    Assert-SamePath ([string]$state.codexEntry) (Join-Path $UserHome '.codex\AGENTS.md') 'codexEntry'
} catch {
    Fail "安装状态路径越界或不匹配：$($_.Exception.Message)"
    exit 1
}
Pass '安装状态可读且归属正确'

$rulesDir = [string]$state.rulesDir
$pickerPath = [string]$state.pickerPath
$configPath = [string]$state.configPath
foreach ($path in @($rulesDir, $pickerPath, $configPath)) {
    if (Test-Path -LiteralPath $path) { Pass "存在：$path" } else { Fail "缺失：$path" }
}

$markerPath = Join-Path $rulesDir '.portable-package-owner.json'
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    try {
        $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($marker.packageId -eq $PackageId) { Pass '规则目录所有权标记' } else { Fail '规则目录所有权标记不匹配' }
    } catch { Fail '规则目录所有权标记损坏' }
} else { Fail '规则目录所有权标记缺失' }

Test-InstalledManifest $rulesDir

$ruleEntry = (Join-Path $rulesDir 'CLAUDE.md').Replace('\','/')
Test-ManagedEntry ([string]$state.claudeEntry) $ruleEntry
Test-ManagedEntry ([string]$state.codexEntry) $ruleEntry

try {
    $cfg = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $ids = @($cfg.tools | ForEach-Object { $_.id })
    if (($ids -join ',') -eq 'claude,codex,grok') { Pass '启动器工具配置：Claude、Codex、Grok' }
    else { Fail '启动器工具配置或顺序不正确' }
} catch { Fail "启动器配置无法解析：$($_.Exception.Message)" }

if (Test-Path -LiteralPath $pickerPath -PathType Leaf) {
    $pickerHash = (Get-FileHash -LiteralPath $pickerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pickerHash -eq [string]$state.hashes.picker) { Pass '启动器哈希' } else { Fail '启动器哈希不匹配' }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pickerPath -SelfTest 2>&1
    if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'SELFTEST PASS') { Pass '启动器 SELFTEST' }
    else { Fail "启动器 SELFTEST：$($output -join ' ')" }
}

$docsScript = Join-Path $rulesDir 'tools\check_docs.ps1'
if (Test-Path -LiteralPath $docsScript -PathType Leaf) {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $docsScript -ProjectRoot $rulesDir -SkipStateCheck 2>&1
    if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'PASS') { Pass '全局规则文档结构与链接' }
    else { Fail "全局规则文档检查：$($output -join ' ')" }
}

$tokens = Get-ChildItem -LiteralPath $rulesDir -Recurse -File | Select-String -SimpleMatch '{{GLOBAL_RULES_ROOT}}','{{CLAUDE_ENTRY_PATH}}','{{LAUNCHER_PATH}}','{{BACKUP_ROOT}}' -ErrorAction SilentlyContinue
if ($tokens) { Fail '规则目录仍含安装令牌' } else { Pass '安装令牌已全部替换' }

if (-not $SkipRegistry -and -not [bool]$state.registrySkipped) {
    foreach ($path in @(
        'HKCU:\Software\Classes\Directory\shell\AITerminalHere',
        'HKCU:\Software\Classes\Directory\Background\shell\AITerminalHere'
    )) {
        if (-not (Test-Path -LiteralPath $path)) { Fail "右键项缺失：$path"; continue }
        $marker = (Get-ItemProperty -LiteralPath $path -Name 'AIContextLauncherManaged' -ErrorAction SilentlyContinue).AIContextLauncherManaged
        $command = (Get-Item -LiteralPath (Join-Path $path 'command')).GetValue('')
        if ($marker -eq $PackageId -and $command -like "*$pickerPath*") { Pass "右键项：$path" }
        else { Fail "右键项内容不匹配：$path" }
    }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "检查失败：$($script:Failures.Count) 项。" -ForegroundColor Red
    exit 1
}
Write-Host '检查完成：全部通过。' -ForegroundColor Green
exit 0
