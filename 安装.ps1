[CmdletBinding()]
param(
    [string]$UserHome = $env:USERPROFILE,
    [string]$RulesDir = '',
    [string]$LauncherDir = '',
    [string]$ClaudeExe = '',
    [string]$CodexExe = '',
    [string]$TestRoot = '',
    [switch]$SkipRegistry,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$PackageId = 'ai-global-rules-context-launcher-v1'
$ManagedBegin = '<!-- AI-GLOBAL-RULES:BEGIN -->'
$ManagedEnd = '<!-- AI-GLOBAL-RULES:END -->'
$RegistryKeyName = 'AITerminalHere'
$MenuText = '在此打开 AI 终端'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Write-Utf8Bom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}
function Get-TextEncoding([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (New-Object Text.UTF8Encoding($false)) }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return (New-Object Text.UTF8Encoding($true))
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return (New-Object Text.UnicodeEncoding($false, $true))
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return (New-Object Text.UnicodeEncoding($true, $true))
    }
    return (New-Object Text.UTF8Encoding($false))
}
function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
}
function ConvertTo-ForwardPath([string]$Path) { return $Path.Replace('\', '/') }
function Assert-ChildPath([string]$Child, [string]$Parent, [string]$Name) {
    $childFull = (Get-FullPath $Child) + '\'
    $parentFull = (Get-FullPath $Parent) + '\'
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name 必须位于用户目录内：$Child"
    }
}
function Get-RelativePath([string]$Root, [string]$FullName) {
    $rootFull = (Get-FullPath $Root) + '\'
    $fileFull = Get-FullPath $FullName
    if (-not $fileFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "文件不在根目录内：$FullName"
    }
    return $fileFull.Substring($rootFull.Length).Replace('\', '/')
}
function Resolve-Executable([string]$Explicit, [string[]]$Names, [string[]]$Fallbacks) {
    if ($Explicit) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Explicit)
        if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
            throw "指定的可执行文件不存在：$expanded"
        }
        return (Get-FullPath $expanded)
    }
    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            $candidate = if ($cmd.Path) { $cmd.Path } else { $cmd.Source }
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                return (Get-FullPath $candidate)
            }
        }
    }
    foreach ($fallback in $Fallbacks) {
        $expanded = [Environment]::ExpandEnvironmentVariables($fallback)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) { return (Get-FullPath $expanded) }
    }
    return ''
}
function Test-PackageManifest([string]$Root) {
    $manifestPath = Join-Path $Root 'manifest.sha256'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw '缺少 manifest.sha256，请完整解压后再安装。'
    }
    $count = 0
    foreach ($line in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "清单格式错误：$line" }
        $expected = $Matches[1]
        $relative = $Matches[2]
        if ([IO.Path]::IsPathRooted($relative) -or $relative -split '/' -contains '..') {
            throw "清单含不安全路径：$relative"
        }
        $path = Join-Path $Root ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "清单文件缺失：$relative" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "清单校验失败：$relative" }
        $count++
    }
    if ($count -lt 5) { throw '清单条目异常过少。' }
    return $count
}
function ConvertTo-NativeRegistryPath([string]$Path) {
    if (-not $Path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "只允许备份 HKCU：$Path"
    }
    return 'HKEY_CURRENT_USER\' + $Path.Substring(6)
}
function Get-RegistrySnapshot([string]$Path, [string]$ExportFile) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ path = $Path; exists = $false; exportFile = '' }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $ExportFile) -Force | Out-Null
    & reg.exe export (ConvertTo-NativeRegistryPath $Path) $ExportFile /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) {
        throw "注册表完整导出失败：$Path"
    }
    return [pscustomobject]@{ path = $Path; exists = $true; exportFile = $ExportFile }
}
function Backup-IfExists([string]$Path, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Copy-Item -LiteralPath $Path -Destination $Destination -Recurse -Force
    } else {
        Copy-Item -LiteralPath $Path -Destination $Destination -Force
    }
    return $true
}
function Assert-ManagedBlockHealthy([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = [IO.File]::ReadAllText($Path, (Get-TextEncoding $Path))
    $beginCount = [regex]::Matches($text, [regex]::Escape($ManagedBegin)).Count
    $endCount = [regex]::Matches($text, [regex]::Escape($ManagedEnd)).Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) {
        throw "受管块损坏或重复，尚未写入任何安装文件：$Path"
    }
}
function Update-ManagedBlock([string]$Path, [string]$Block, [string]$BackupDir) {
    $text = ''
    $encoding = New-Object Text.UTF8Encoding($false)
    $fileExisted = Test-Path -LiteralPath $Path -PathType Leaf
    if ($fileExisted) {
        $encoding = Get-TextEncoding $Path
        $text = [IO.File]::ReadAllText($Path, $encoding)
        [void](Backup-IfExists $Path (Join-Path $BackupDir ([IO.Path]::GetFileName($Path))))
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    }
    $beginCount = [regex]::Matches($text, [regex]::Escape($ManagedBegin)).Count
    $endCount = [regex]::Matches($text, [regex]::Escape($ManagedEnd)).Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) {
        throw "受管块损坏或重复，拒绝覆盖：$Path"
    }
    if ($beginCount -eq 1) {
        $pattern = '(?s)' + [regex]::Escape($ManagedBegin) + '.*?' + [regex]::Escape($ManagedEnd)
        $newText = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $Block }, 1)
        $metadata = [pscustomobject]@{ appended=$false; fileExisted=[bool]$fileExisted; separator=''; suffix='' }
    } else {
        $separator = if ($text.Length -eq 0 -or $text.EndsWith("`n")) { '' } else { "`r`n" }
        $suffix = "`r`n"
        $newText = $text + $separator + $Block + $suffix
        $metadata = [pscustomobject]@{ appended=$true; fileExisted=[bool]$fileExisted; separator=$separator; suffix=$suffix }
    }
    [IO.File]::WriteAllText($Path, $newText, $encoding)
    return $metadata
}
function New-InstalledManifest([string]$Root) {
    $manifestPath = Join-Path $Root '.installed-manifest.sha256'
    $lines = @()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName) {
        if ($file.FullName -eq $manifestPath -or $file.Name -eq '.portable-package-owner.json') { continue }
        $relative = Get-RelativePath $Root $file.FullName
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$hash  $relative"
    }
    Write-Utf8NoBom $manifestPath (($lines -join "`n") + "`n")
    return $lines.Count
}

if ($TestRoot) {
    $testFull = Get-FullPath $TestRoot
    $UserHome = Join-Path $testFull 'User'
    $SkipRegistry = $true
}
$UserHome = Get-FullPath $UserHome
New-Item -ItemType Directory -Path $UserHome -Force | Out-Null
if (-not $RulesDir) { $RulesDir = Join-Path $UserHome '.ai-global-rules' }
if (-not $LauncherDir) { $LauncherDir = Join-Path $UserHome '.local\bin' }
$RulesDir = Get-FullPath $RulesDir
$LauncherDir = Get-FullPath $LauncherDir
Assert-ChildPath $RulesDir $UserHome 'RulesDir'
Assert-ChildPath $LauncherDir $UserHome 'LauncherDir'

$payloadRules = Join-Path $PSScriptRoot 'payload\global-rules'
$payloadLauncher = Join-Path $PSScriptRoot 'payload\launcher\ai-picker.ps1'
$configTemplate = Join-Path $PSScriptRoot 'payload\launcher\ai-tools.template.json'
foreach ($required in @($payloadRules, $payloadLauncher, $configTemplate)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "安装包缺少：$required" }
}

Write-Step '验证安装包完整性'
$verifiedFiles = Test-PackageManifest $PSScriptRoot
Write-Ok "SHA-256 清单通过（$verifiedFiles 个文件）"

# Windows 10 需要先安装 Terminal；隔离测试不启动外部安装程序。
if (-not $TestRoot) {
    $build = [Environment]::OSVersion.Version.Build
    if ([Environment]::OSVersion.Version.Major -eq 10 -and $build -lt 22000) {
        Write-Step '检查 Windows Terminal'
        $terminalPackage = @(Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue)
        $terminalCommand = Resolve-Executable '' @('wt.exe') @('%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe')
        if ($terminalPackage.Count -eq 0 -or -not $terminalCommand) {
            $terminalInstaller = Join-Path $PSScriptRoot 'Windows Terminal Installer.exe'
            if (-not (Test-Path -LiteralPath $terminalInstaller -PathType Leaf)) { throw '缺少 Windows Terminal Installer.exe，请完整复制安装包。' }
            Write-Warn2 'Windows 10 尚未检测到可用的 Windows Terminal，将打开安装程序。'
            Write-Warn2 '请在打开的窗口中完成安装；安装完成后回到此窗口按回车。'
            Start-Process -FilePath $terminalInstaller | Out-Null
            [void](Read-Host '完成安装后按回车继续')
            $terminalPackage = @(Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue)
            $terminalCommand = Resolve-Executable '' @('wt.exe') @('%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe')
            if ($terminalPackage.Count -eq 0 -or -not $terminalCommand) {
                throw '尚未检测到 Windows Terminal 或 wt.exe。请完成安装并启用应用执行别名，然后重新运行安装.cmd。'
            }
        }
        Write-Ok '已检测到 Windows Terminal。'
    }
}

$claudePath = Resolve-Executable $ClaudeExe @('claude.exe','claude.cmd','claude') @('%APPDATA%\npm\claude.cmd','%APPDATA%\npm\claude.exe')
$codexPath = Resolve-Executable $CodexExe @('codex.exe','codex.cmd','codex') @('%APPDATA%\npm\codex.cmd','%APPDATA%\npm\codex.exe')

$statePath = Join-Path $UserHome '.ai-global-rules-install.json'
$priorState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $priorState = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw "已有安装状态损坏：$statePath" }
    if ($priorState.packageId -ne $PackageId -and -not $Force) { throw '检测到其他安装器的状态文件；如确认覆盖请加 -Force。' }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $UserHome '.ai-global-rules-backup'
$operationBackup = Join-Path $backupRoot ($stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $operationBackup -Force | Out-Null

$pickerPath = Join-Path $LauncherDir 'ai-picker.ps1'
$configPath = Join-Path $LauncherDir 'ai-tools.json'
$claudeEntry = Join-Path $UserHome '.claude\CLAUDE.md'
$codexEntry = Join-Path $UserHome '.codex\AGENTS.md'
$ownerMarker = Join-Path $RulesDir '.portable-package-owner.json'
Assert-ManagedBlockHealthy $claudeEntry
Assert-ManagedBlockHealthy $codexEntry

if ($priorState -and $priorState.packageId -eq $PackageId) {
    $original = $priorState.original
} else {
    $originalDir = Join-Path $operationBackup 'original'
    New-Item -ItemType Directory -Path $originalDir -Force | Out-Null
    $rulesExisted = Test-Path -LiteralPath $RulesDir -PathType Container
    if ($rulesExisted) {
        $existingMarker = Join-Path $RulesDir '.portable-package-owner.json'
        if (-not (Test-Path -LiteralPath $existingMarker -PathType Leaf) -and -not $Force) {
            throw "规则目录已存在且不是本安装器所有：$RulesDir。确认覆盖请加 -Force。"
        }
        [void](Backup-IfExists $RulesDir (Join-Path $originalDir 'global-rules'))
    }
    $pickerExisted = Backup-IfExists $pickerPath (Join-Path $originalDir 'ai-picker.ps1')
    $configExisted = Backup-IfExists $configPath (Join-Path $originalDir 'ai-tools.json')
    $stateExisted = Backup-IfExists $statePath (Join-Path $originalDir 'install-state.json')
    $registrySnapshots = @()
    if (-not $SkipRegistry) {
        $registryBackupDir = Join-Path $originalDir 'registry'
        $registrySnapshots = @(
            (Get-RegistrySnapshot "HKCU:\Software\Classes\Directory\shell\$RegistryKeyName" (Join-Path $registryBackupDir 'directory-shell.reg'))
            (Get-RegistrySnapshot "HKCU:\Software\Classes\Directory\Background\shell\$RegistryKeyName" (Join-Path $registryBackupDir 'directory-background.reg'))
        )
    }
    $original = [pscustomobject]@{
        backupDir = $originalDir
        rulesExisted = [bool]$rulesExisted
        pickerExisted = [bool]$pickerExisted
        configExisted = [bool]$configExisted
        stateExisted = [bool]$stateExisted
        registrySnapshots = @($registrySnapshots)
    }
}

Write-Step '安装全局规则'
$stageRules = Join-Path $UserHome ('.ai-global-rules.installing-' + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath $payloadRules -Destination $stageRules -Recurse -Force
$tokenMap = [ordered]@{
    '{{GLOBAL_RULES_ROOT}}' = ConvertTo-ForwardPath $RulesDir
    '{{CLAUDE_ENTRY_PATH}}' = ConvertTo-ForwardPath $claudeEntry
    '{{LAUNCHER_PATH}}' = ConvertTo-ForwardPath $pickerPath
    '{{BACKUP_ROOT}}' = ConvertTo-ForwardPath $backupRoot
}
$textExtensions = @('.md','.py','.ps1','.tsv','.txt','.json','.yaml','.yml')
foreach ($file in Get-ChildItem -LiteralPath $stageRules -Recurse -File) {
    if ($textExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    foreach ($token in $tokenMap.Keys) { $text = $text.Replace($token, [string]$tokenMap[$token]) }
    if ($file.Extension -ieq '.ps1') { Write-Utf8Bom $file.FullName $text }
    else { Write-Utf8NoBom $file.FullName $text }
}
$owner = [pscustomobject]@{ packageId=$PackageId; installedAt=[datetimeoffset]::Now.ToString('o'); sourcePackage=$PSScriptRoot }
Write-Utf8NoBom (Join-Path $stageRules '.portable-package-owner.json') ($owner | ConvertTo-Json -Depth 4)
[void](New-InstalledManifest $stageRules)
if (Test-Path -LiteralPath $RulesDir) {
    Move-Item -LiteralPath $RulesDir -Destination (Join-Path $operationBackup 'replaced-global-rules')
}
Move-Item -LiteralPath $stageRules -Destination $RulesDir
Write-Ok $RulesDir

Write-Step '安装右键启动器'
New-Item -ItemType Directory -Path $LauncherDir -Force | Out-Null
[void](Backup-IfExists $pickerPath (Join-Path $operationBackup 'current-ai-picker.ps1'))
[void](Backup-IfExists $configPath (Join-Path $operationBackup 'current-ai-tools.json'))
Copy-Item -LiteralPath $payloadLauncher -Destination $pickerPath -Force

$template = [IO.File]::ReadAllText($configTemplate, [Text.Encoding]::UTF8)
$template = $template.Replace('{{CLAUDE_EXE}}', (ConvertTo-ForwardPath $claudePath).Replace('\','\\'))
$template = $template.Replace('{{CODEX_EXE}}', (ConvertTo-ForwardPath $codexPath).Replace('\','\\'))
$toolConfig = $template | ConvertFrom-Json
foreach ($item in @($toolConfig.tools)) {
    if ($item.id -eq 'claude') { $item.exe = $claudePath }
    if ($item.id -eq 'codex') { $item.exe = $codexPath }
}
Write-Utf8NoBom $configPath ($toolConfig | ConvertTo-Json -Depth 16)
Write-Ok '已配置 Claude、Codex 和 Grok；启动时检测是否安装。'

Write-Step '接入 Claude Code 与 Codex 全局入口'
$rulesForward = ConvertTo-ForwardPath (Join-Path $RulesDir 'CLAUDE.md')
$memoryForward = ConvertTo-ForwardPath (Join-Path $RulesDir 'memory\README.md')
$claudeBlock = $ManagedBegin + "`r`n@" + $rulesForward + "`r`n" + $ManagedEnd
$codexBlock = @"
$ManagedBegin
# 通用记忆宫殿

每次开始实质任务前，先完整读取 $rulesForward，再读取 $memoryForward 并按问题路由加载相关模块；之后再读取项目级规则和用户当轮指令。默认使用简体中文与 UTF-8。平台系统/开发者指令优先于本地规则。
$ManagedEnd
"@.Trim()
$currentClaudeEntryInstall = Update-ManagedBlock $claudeEntry $claudeBlock (Join-Path $operationBackup 'entries')
$currentCodexEntryInstall = Update-ManagedBlock $codexEntry $codexBlock (Join-Path $operationBackup 'entries')
$entryInstall = if ($priorState -and $priorState.packageId -eq $PackageId -and $priorState.PSObject.Properties['entryInstall']) {
    $priorState.entryInstall
} else {
    [pscustomobject]@{ claude=$currentClaudeEntryInstall; codex=$currentCodexEntryInstall }
}
Write-Ok $claudeEntry
Write-Ok $codexEntry

$registryMode = '跳过（隔离测试）'
if (-not $SkipRegistry) {
    Write-Step '写入右键菜单（仅 HKCU，无需管理员权限）'
    $shell = Resolve-Executable '' @('pwsh.exe','powershell.exe') @('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe')
    $wt = Resolve-Executable '' @('wt.exe') @('%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe')
    $targets = @(
        [pscustomobject]@{ path="HKCU:\Software\Classes\Directory\shell\$RegistryKeyName"; variable='%1' },
        [pscustomobject]@{ path="HKCU:\Software\Classes\Directory\Background\shell\$RegistryKeyName"; variable='%V' }
    )
    foreach ($target in $targets) {
        $command = if ($wt) {
            '"{0}" -d "{1}" "{2}" -NoExit -NoProfile -ExecutionPolicy Bypass -File "{3}" -WorkingDir "{1}"' -f $wt, $target.variable, $shell, $pickerPath
        } else {
            '"{0}" -NoExit -NoProfile -ExecutionPolicy Bypass -File "{1}" -WorkingDir "{2}"' -f $shell, $pickerPath, $target.variable
        }
        New-Item -Path $target.path -Force | Out-Null
        New-ItemProperty -Path $target.path -Name 'MUIVerb' -Value $MenuText -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $target.path -Name 'AIContextLauncherManaged' -Value $PackageId -PropertyType String -Force | Out-Null
        New-Item -Path (Join-Path $target.path 'command') -Force | Out-Null
        Set-Item -LiteralPath (Join-Path $target.path 'command') -Value $command
    }
    $registryMode = if ($wt) { 'Windows Terminal' } else { 'Windows PowerShell' }
    Write-Ok "启动方式：$registryMode"
}

$installedRulesManifest = Join-Path $RulesDir '.installed-manifest.sha256'
$state = [pscustomobject]@{
    version = 1
    packageId = $PackageId
    installedAt = [datetimeoffset]::Now.ToString('o')
    userHome = $UserHome
    rulesDir = $RulesDir
    launcherDir = $LauncherDir
    pickerPath = $pickerPath
    configPath = $configPath
    claudeEntry = $claudeEntry
    codexEntry = $codexEntry
    registrySkipped = [bool]$SkipRegistry
    registryMode = $registryMode
    operationBackup = $operationBackup
    original = $original
    entryInstall = $entryInstall
    hashes = [pscustomobject]@{
        picker = (Get-FileHash -LiteralPath $pickerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        config = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
        rulesManifest = (Get-FileHash -LiteralPath $installedRulesManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
Write-Utf8NoBom $statePath ($state | ConvertTo-Json -Depth 16)

Write-Step '运行安装后自检'
$selfTestOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pickerPath -SelfTest 2>&1
if ($LASTEXITCODE -ne 0 -or ($selfTestOutput -join "`n") -notmatch 'SELFTEST PASS') {
    throw "启动器自检失败：$($selfTestOutput -join ' ')"
}
$docsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RulesDir 'tools\check_docs.ps1') -ProjectRoot $RulesDir -SkipStateCheck 2>&1
if ($LASTEXITCODE -ne 0 -or ($docsOutput -join "`n") -notmatch 'PASS') {
    throw "规则文档自检失败：$($docsOutput -join ' ')"
}
$tokenLeak = Get-ChildItem -LiteralPath $RulesDir -Recurse -File | Select-String -SimpleMatch '{{GLOBAL_RULES_ROOT}}','{{CLAUDE_ENTRY_PATH}}','{{LAUNCHER_PATH}}','{{BACKUP_ROOT}}' -ErrorAction SilentlyContinue
if ($tokenLeak) { throw '安装后的规则仍含未替换令牌。' }
Write-Ok '启动器 SELFTEST PASS；规则文档检查 PASS；未发现残留令牌。'

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host "  全局规则：$RulesDir" -ForegroundColor Gray
Write-Host "  启动器：  $pickerPath" -ForegroundColor Gray
Write-Host "  右键菜单：$MenuText（$registryMode）" -ForegroundColor Gray
Write-Host "  回退备份：$operationBackup" -ForegroundColor Gray
Write-Host ''
