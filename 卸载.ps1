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

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
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
function Assert-ChildPath([string]$Child, [string]$Parent, [string]$Name) {
    $childFull = (Get-FullPath $Child) + '\'
    $parentFull = (Get-FullPath $Parent) + '\'
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "状态文件中的 $Name 超出允许范围：$Child"
    }
}
function Assert-SamePath([string]$Actual, [string]$Expected, [string]$Name) {
    if ((Get-FullPath $Actual) -ine (Get-FullPath $Expected)) {
        throw "状态文件中的 $Name 不匹配：$Actual"
    }
}
function Backup-IfExists([string]$Path, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Copy-Item -LiteralPath $Path -Destination $Destination -Recurse -Force
    } else {
        Copy-Item -LiteralPath $Path -Destination $Destination -Force
    }
    return $true
}
function Remove-ManagedBlock([string]$Path, [string]$BackupDir, [object]$InstallMetadata) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $encoding = Get-TextEncoding $Path
    $text = [IO.File]::ReadAllText($Path, $encoding)
    $beginCount = [regex]::Matches($text, [regex]::Escape($ManagedBegin)).Count
    $endCount = [regex]::Matches($text, [regex]::Escape($ManagedEnd)).Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) {
        throw "受管块损坏或重复，拒绝自动删除：$Path"
    }
    if ($beginCount -eq 0) { Write-Warn2 "未找到受管块，保留：$Path"; return }
    [void](Backup-IfExists $Path (Join-Path $BackupDir ([IO.Path]::GetFileName($Path))))
    $pattern = '(?s)' + [regex]::Escape($ManagedBegin) + '.*?' + [regex]::Escape($ManagedEnd)
    $match = [regex]::Match($text, $pattern)
    $start = $match.Index
    $end = $match.Index + $match.Length
    $fileExisted = $true
    if ($InstallMetadata -and [bool]$InstallMetadata.appended) {
        $separator = [string]$InstallMetadata.separator
        $suffix = [string]$InstallMetadata.suffix
        $fileExisted = [bool]$InstallMetadata.fileExisted
        if ($separator.Length -gt 0 -and $start -ge $separator.Length -and $text.Substring($start - $separator.Length, $separator.Length) -ceq $separator) {
            $start -= $separator.Length
        }
        if ($suffix.Length -gt 0 -and $end + $suffix.Length -le $text.Length -and $text.Substring($end, $suffix.Length) -ceq $suffix) {
            $end += $suffix.Length
        }
    }
    $newText = $text.Remove($start, $end - $start)
    if (-not $fileExisted -and $newText.Length -eq 0) {
        Remove-Item -LiteralPath $Path -Force
    } else {
        [IO.File]::WriteAllText($Path, $newText, $encoding)
    }
}
function Restore-RegistrySnapshot([object]$Snapshot) {
    $path = [string]$Snapshot.path
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    if (-not [bool]$Snapshot.exists) { return }
    $exportFile = [string]$Snapshot.exportFile
    if (-not (Test-Path -LiteralPath $exportFile -PathType Leaf)) {
        throw "注册表完整备份缺失：$exportFile"
    }
    & reg.exe import $exportFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "注册表恢复失败：$path"
    }
}

if ($TestRoot) {
    $UserHome = Join-Path (Get-FullPath $TestRoot) 'User'
    $SkipRegistry = $true
}
$UserHome = Get-FullPath $UserHome
$statePath = Join-Path $UserHome '.ai-global-rules-install.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "未找到安装状态：$statePath"
}
$state = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if ($state.packageId -ne $PackageId) { throw '安装状态不属于本便携包，拒绝卸载。' }
$stateHome = Get-FullPath ([string]$state.userHome)
if ($stateHome -ine $UserHome) { throw "安装状态属于其他用户目录：$stateHome" }
$backupRoot = Join-Path $UserHome '.ai-global-rules-backup'
$rulesDir = Get-FullPath ([string]$state.rulesDir)
$launcherDir = Get-FullPath ([string]$state.launcherDir)
$pickerPath = Get-FullPath ([string]$state.pickerPath)
$configPath = Get-FullPath ([string]$state.configPath)
$claudeEntry = Get-FullPath ([string]$state.claudeEntry)
$codexEntry = Get-FullPath ([string]$state.codexEntry)
$originalBackupDir = Get-FullPath ([string]$state.original.backupDir)
Assert-ChildPath $rulesDir $UserHome 'rulesDir'
Assert-ChildPath $launcherDir $UserHome 'launcherDir'
Assert-SamePath $pickerPath (Join-Path $launcherDir 'ai-picker.ps1') 'pickerPath'
Assert-SamePath $configPath (Join-Path $launcherDir 'ai-tools.json') 'configPath'
Assert-SamePath $claudeEntry (Join-Path $UserHome '.claude\CLAUDE.md') 'claudeEntry'
Assert-SamePath $codexEntry (Join-Path $UserHome '.codex\AGENTS.md') 'codexEntry'
Assert-ChildPath $originalBackupDir $backupRoot 'original.backupDir'
if ($state.PSObject.Properties['operationBackup']) {
    Assert-ChildPath ([string]$state.operationBackup) $backupRoot 'operationBackup'
}
$allowedRegistryPaths = @(
    'HKCU:\Software\Classes\Directory\shell\AITerminalHere',
    'HKCU:\Software\Classes\Directory\Background\shell\AITerminalHere'
)
foreach ($snapshot in @($state.original.registrySnapshots)) {
    if ([string]$snapshot.path -notin $allowedRegistryPaths) { throw "状态文件含越界注册表路径：$($snapshot.path)" }
    if ([bool]$snapshot.exists) { Assert-ChildPath ([string]$snapshot.exportFile) $backupRoot 'registry exportFile' }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$uninstallBackup = Join-Path $backupRoot ('uninstall-' + $stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $uninstallBackup -Force | Out-Null

Write-Step '移除 Claude Code / Codex 受管入口块'
$claudeEntryInstall = if ($state.PSObject.Properties['entryInstall']) { $state.entryInstall.claude } else { $null }
$codexEntryInstall = if ($state.PSObject.Properties['entryInstall']) { $state.entryInstall.codex } else { $null }
Remove-ManagedBlock $claudeEntry (Join-Path $uninstallBackup 'entries') $claudeEntryInstall
Remove-ManagedBlock $codexEntry (Join-Path $uninstallBackup 'entries') $codexEntryInstall
Write-Ok '只移除本安装器标记块，块外内容保留。'

if (-not $SkipRegistry -and -not [bool]$state.registrySkipped) {
    Write-Step '恢复安装前的右键菜单状态'
    foreach ($snapshot in @($state.original.registrySnapshots)) {
        $current = $null
        if (Test-Path -LiteralPath ([string]$snapshot.path)) {
            $current = (Get-ItemProperty -LiteralPath ([string]$snapshot.path) -Name 'AIContextLauncherManaged' -ErrorAction SilentlyContinue).AIContextLauncherManaged
        }
        if ($current -and $current -ne $PackageId) {
            Write-Warn2 "右键项已被其他程序接管，保留：$($snapshot.path)"
            continue
        }
        Restore-RegistrySnapshot $snapshot
        Write-Ok ([string]$snapshot.path)
    }
}

Write-Step '移走已安装规则并恢复原目录（如有）'
$rulesOwned = $false
if (Test-Path -LiteralPath $rulesDir -PathType Container) {
    $marker = Join-Path $rulesDir '.portable-package-owner.json'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        try { $rulesOwned = (([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) | ConvertFrom-Json).packageId -eq $PackageId) } catch { }
    }
    if (-not $rulesOwned) { throw "规则目录已不属于本安装器，拒绝移动：$rulesDir" }
    Move-Item -LiteralPath $rulesDir -Destination (Join-Path $uninstallBackup 'installed-global-rules')
}
if ([bool]$state.original.rulesExisted) {
    $originalRules = Join-Path $originalBackupDir 'global-rules'
    if (-not (Test-Path -LiteralPath $originalRules -PathType Container)) { throw '原规则目录备份缺失，已安装副本仍保存在卸载备份中。' }
    Copy-Item -LiteralPath $originalRules -Destination $rulesDir -Recurse -Force
    Write-Ok "已恢复原目录：$rulesDir"
} else {
    Write-Ok '安装前没有规则目录；已将安装副本移入可恢复卸载备份。'
}

Write-Step '恢复或移走启动器文件'
foreach ($entry in @(
    [pscustomobject]@{ path=$pickerPath; existed=[bool]$state.original.pickerExisted; backup='ai-picker.ps1' },
    [pscustomobject]@{ path=$configPath; existed=[bool]$state.original.configExisted; backup='ai-tools.json' }
)) {
    if (Test-Path -LiteralPath $entry.path -PathType Leaf) {
        Move-Item -LiteralPath $entry.path -Destination (Join-Path $uninstallBackup ([IO.Path]::GetFileName($entry.path))) -Force
    }
    if ($entry.existed) {
        $source = Join-Path $originalBackupDir $entry.backup
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "原文件备份缺失：$source" }
        Copy-Item -LiteralPath $source -Destination $entry.path -Force
        Write-Ok "已恢复：$($entry.path)"
    } else {
        Write-Ok "已移走：$($entry.path)"
    }
}

if ([bool]$state.original.stateExisted) {
    $oldState = Join-Path $originalBackupDir 'install-state.json'
    Copy-Item -LiteralPath $oldState -Destination $statePath -Force
} else {
    Move-Item -LiteralPath $statePath -Destination (Join-Path $uninstallBackup 'install-state.json') -Force
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
Write-Host "  可恢复副本：$uninstallBackup" -ForegroundColor Gray
Write-Host '  未删除：Claude/Codex 会话、启动器会话状态、项目 .ai-session 锚点。' -ForegroundColor Gray
Write-Host ''
