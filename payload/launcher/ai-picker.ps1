# AI 终端选择器：Windows 右键菜单的唯一入口。
# 交互流程：选择 AI -> 选择网络 -> Codex 选择账号 -> 启动工具。
param(
    [string]$Tool,
    [string]$Network,
    [string]$WorkingDir,
    [switch]$SelfTest,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PickerVersion = '0.0.1'
$script:BackToken = [pscustomobject]@{ kind = '__back__' }

$configPath = Join-Path $PSScriptRoot 'ai-tools.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "配置文件不存在: $configPath" -ForegroundColor Red
    exit 1
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tools = @($config.tools)
$networks = @($config.networks)

function Test-IsBack {
    param([object]$Value)
    return [object]::ReferenceEquals($Value, $script:BackToken)
}

function Select-FromList {
    param(
        [string]$Title,
        [object[]]$Items,
        [string[]]$Labels,
        [bool]$FirstStep = $false
    )

    if ($Items.Count -eq 0 -or $Items.Count -ne $Labels.Count) {
        throw "选择列表数据无效: $Title"
    }

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Labels[$i])
    }
    $backText = if ($FirstStep) { '按 ↑ 退出。' } else { '按 ↑ 返回选择 AI。' }
    Write-Host ("  直接回车 = 1；{0}" -f $backText) -ForegroundColor DarkGray

    if ($Items.Count -le 9) {
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::UpArrow) {
                Write-Host '  -> 返回' -ForegroundColor Yellow
                return $script:BackToken
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $picked = 0
            } else {
                $n = 0
                if (-not [int]::TryParse($key.KeyChar.ToString(), [ref]$n)) { continue }
                if ($n -lt 1 -or $n -gt $Items.Count) { continue }
                $picked = $n - 1
            }
            Write-Host ("  -> {0}" -f $Labels[$picked]) -ForegroundColor Green
            return $Items[$picked]
        }
    }

    Write-Host '  序号: ' -NoNewline
    $buffer = ''
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::UpArrow) {
            Write-Host ''
            Write-Host '  -> 返回' -ForegroundColor Yellow
            return $script:BackToken
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                $buffer = $buffer.Substring(0, $buffer.Length - 1)
                Write-Host ([char]8) -NoNewline
                Write-Host ' ' -NoNewline
                Write-Host ([char]8) -NoNewline
            }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            $n = 1
            if ($buffer -and -not [int]::TryParse($buffer, [ref]$n)) { continue }
            if ($n -lt 1 -or $n -gt $Items.Count) {
                Write-Host ''
                Write-Host '  序号无效，请重新输入: ' -ForegroundColor Yellow -NoNewline
                $buffer = ''
                continue
            }
            $picked = $n - 1
            Write-Host ''
            Write-Host ("  -> {0}" -f $Labels[$picked]) -ForegroundColor Green
            return $Items[$picked]
        }
        if ([char]::IsDigit($key.KeyChar)) {
            $buffer += $key.KeyChar
            Write-Host $key.KeyChar -NoNewline
        }
    }
}

function Resolve-ByNameOrIndex {
    param([object[]]$Items, [string]$Value, [string]$What)
    $n = 0
    if ([int]::TryParse($Value, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
        return $Items[$n - 1]
    }
    $hit = $Items | Where-Object { $_.name -eq $Value -or $_.id -eq $Value } | Select-Object -First 1
    if (-not $hit) {
        Write-Host ("未找到{0}: {1}（可用: {2}）" -f $What, $Value, (($Items | ForEach-Object name) -join ', ')) -ForegroundColor Red
        exit 1
    }
    return $hit
}

function Resolve-Directory {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables([string]$Path).Trim().Trim('"')
    if ($expanded -match '^file:/') {
        try { $expanded = ([Uri]$expanded).LocalPath } catch { }
    }
    if (-not $expanded -or -not (Test-Path -LiteralPath $expanded -PathType Container)) {
        Write-Host ("启动目录不存在: {0}" -f $expanded) -ForegroundColor Red
        exit 1
    }
    $resolved = (Resolve-Path -LiteralPath $expanded).Path
    $providerPrefix = 'Microsoft.PowerShell.Core\FileSystem::'
    if ($resolved.StartsWith($providerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $resolved = $resolved.Substring($providerPrefix.Length)
    }
    return $resolved
}

function Invoke-SelfTest {
    $failures = @()
    if ($tools.Count -eq 0) { $failures += 'tools-empty' }
    if ($networks.Count -eq 0) { $failures += 'networks-empty' }
    foreach ($toolItem in $tools) {
        if (-not $toolItem.name -or -not $toolItem.id) { $failures += 'tool-fields'; break }
    }
    foreach ($networkItem in $networks) {
        if (-not $networkItem.name) { $failures += 'network-fields'; break }
    }
    foreach ($removedField in @('sessionSources', 'launcher')) {
        if ($config.PSObject.Properties[$removedField]) { $failures += "removed-config-$removedField" }
    }
    if ($failures.Count -gt 0) {
        Write-Host ("SELFTEST FAIL: {0}" -f ($failures -join ', ')) -ForegroundColor Red
        return 1
    }
    Write-Host 'SELFTEST PASS: 启动器配置有效。' -ForegroundColor Green
    return 0
}

Write-Host ("AI 终端选择器 v{0}" -f $PickerVersion) -ForegroundColor DarkGray
if ($SelfTest) { exit (Invoke-SelfTest) }

$workingDir = Resolve-Directory $(if ($WorkingDir) { $WorkingDir } else { (Get-Location).Path })

if ($Tool) {
    $toolSel = Resolve-ByNameOrIndex $tools $Tool 'AI'
    if ($Network) {
        $netSel = Resolve-ByNameOrIndex $networks $Network '代理'
    } else {
        $netSel = Select-FromList ("选择代理（回车 = {0}）" -f $networks[0].name) $networks ($networks | ForEach-Object name)
        if (Test-IsBack $netSel) { exit 0 }
    }
} else {
    while ($true) {
        $toolSel = Select-FromList ("选择 AI（回车 = {0}）" -f $tools[0].name) $tools ($tools | ForEach-Object name) $true
        if (Test-IsBack $toolSel) { exit 0 }
        if ($Network) {
            $netSel = Resolve-ByNameOrIndex $networks $Network '代理'
        } else {
            $netSel = Select-FromList ("选择代理（回车 = {0}）" -f $networks[0].name) $networks ($networks | ForEach-Object name)
            if (Test-IsBack $netSel) { continue }
        }
        break
    }
}

function Find-ToolCommand([string]$Name, [string]$Configured) {
    if ($Configured -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($Configured)) -PathType Leaf)) { return [Environment]::ExpandEnvironmentVariables($Configured) }
    foreach ($candidate in @("$Name.cmd", "$Name.exe", $Name)) {
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
        foreach ($folder in @((Join-Path $env:APPDATA 'npm'), (Join-Path $env:USERPROFILE '.local\bin'))) {
            $path = Join-Path $folder $candidate
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
    }
    return ''
}
function Get-CodexAccountLabel([object]$Account) {
    $email = [string]$Account.email
    $alias = [string]$Account.alias
    $name = [string]$Account.account_name
    if ($Account.auth_mode -eq 'apikey') {
        $identity = if ($name) { $name } elseif ($alias) { $alias } else { '未命名密钥' }
        if ($alias -and $name) { $identity = "$alias / $name" }
        return "API Key $identity $email".Trim()
    }
    $identity = if ($email) { $email } elseif ($alias) { $alias } elseif ($name) { $name } else { '未命名账号' }
    if ($alias -and $email) { $identity = "$alias / $email" }
    return "ChatGPT $identity"
}
$exe = Find-ToolCommand ([string]$toolSel.id) ([string]$toolSel.exe)
if (-not $exe) {
    $links = @{ claude='https://code.claude.com/docs/en/setup'; codex='https://developers.openai.com/codex/cli/'; grok='https://docs.x.ai/build/overview' }
    Write-Host ("未找到 {0}，即将打开安装说明。安装后请重新运行右键启动。" -f $toolSel.name) -ForegroundColor Yellow
    Start-Process $links[[string]$toolSel.id]
    exit 1
}

if ($netSel.proxy) {
    $env:HTTP_PROXY = $netSel.proxy
    $env:HTTPS_PROXY = $netSel.proxy
    $env:ALL_PROXY = $netSel.proxy
} else {
    Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY -ErrorAction SilentlyContinue
}

$toolArgs = @($toolSel.openArgs)

if ($toolSel.id -eq 'codex' -and -not $DryRun) {
    $auth = Find-ToolCommand 'codex-auth' ''
    if (-not $auth) {
        Write-Host '未检测到 codex-auth，正在通过 npm 安装账号管理工具……' -ForegroundColor Yellow
        $npm = Find-ToolCommand 'npm' ''
        if (-not $npm) {
            Write-Host '未检测到 npm，请先安装 Node.js，然后重新启动。' -ForegroundColor Red
            Start-Process 'https://nodejs.org/en/download'
            exit 1
        }
        & $npm install -g '@loongphy/codex-auth'
        if ($LASTEXITCODE -ne 0) { Write-Host 'codex-auth 安装失败，请检查网络或 npm 后重试。' -ForegroundColor Red; exit 1 }
        $auth = Find-ToolCommand 'codex-auth' ''
        if (-not $auth) { Write-Host '安装完成但未找到 codex-auth，请重新打开右键启动。' -ForegroundColor Red; exit 1 }
    }
    Write-Host '正在读取 Codex 账号和额度……' -ForegroundColor Cyan
    & $auth list
    if ($LASTEXITCODE -ne 0) { Write-Host '账号列表读取失败；请检查网络、代理和 codex-auth 配置。API Key 导入需要联网验证。' -ForegroundColor Red; exit 1 }
    try {
        $accountData = (& $auth list --json --skip-api | Out-String) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw '无法读取账号数据' }
        $accounts = @($accountData.accounts)
    } catch { Write-Host '无法读取账号列表，未启动 Codex。' -ForegroundColor Red; exit 1 }
    if ($accounts.Count -eq 0) { Write-Host '没有已保存的账号，请先运行 codex-auth login。' -ForegroundColor Yellow; exit 1 }
    $selected = 0
    for ($i = 0; $i -lt $accounts.Count; $i++) { if ($accounts[$i].active) { $selected = $i; break } }
    Write-Host '使用 ↑ / ↓ 选择账号，回车确认，Esc 取消。默认选中当前账号。' -ForegroundColor Cyan
    $startRow = [Console]::CursorTop
    do {
        [Console]::SetCursorPosition(0, $startRow)
        $selectedLabel = Get-CodexAccountLabel $accounts[$selected]
        $width = [Math]::Max(1, [Console]::WindowWidth - 1)
        $heading = "当前选择为：$selectedLabel"
        $limit = [Math]::Max(1, $width - 8)
        if ($heading.Length -gt $limit) { $heading = $heading.Substring(0, $limit) }
        [Console]::Write((' ' * $width)); [Console]::SetCursorPosition(0, [Console]::CursorTop)
        Write-Host $heading -ForegroundColor Cyan
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $marker = if ($i -eq $selected) { '*' } else { ' ' }
            $active = if ($accounts[$i].active) { '（当前）' } else { '' }
            $label = Get-CodexAccountLabel $accounts[$i]
            $line = " $marker $label $active"
            $width = [Math]::Max(1, [Console]::WindowWidth - 1)
            if ($line.Length -gt $limit) { $line = $line.Substring(0, $limit) }
            [Console]::Write((' ' * $width)); [Console]::SetCursorPosition(0, [Console]::CursorTop)
            Write-Host $line -ForegroundColor $(if ($i -eq $selected) { 'Green' } else { 'Gray' })
        }
        $key = [Console]::ReadKey($true).Key
        if ($key -eq [ConsoleKey]::UpArrow) { $selected = ($selected + $accounts.Count - 1) % $accounts.Count }
        if ($key -eq [ConsoleKey]::DownArrow) { $selected = ($selected + 1) % $accounts.Count }
        if ($key -eq [ConsoleKey]::Escape) { exit 0 }
    } while ($key -ne [ConsoleKey]::Enter)
    if (-not $accounts[$selected].active) {
        $selector = [string]$accounts[$selected].account_key
        if (-not $selector) { Write-Host '账号标识缺失，未启动 Codex。' -ForegroundColor Red; exit 1 }
        & $auth switch $selector --no-restart-daemon
        if ($LASTEXITCODE -ne 0) { Write-Host '账号切换失败，未启动 Codex。' -ForegroundColor Red; exit 1 }
    }
}

Set-Location -LiteralPath $workingDir
Write-Host ''
Write-Host ("AI: {0}" -f $toolSel.name) -ForegroundColor DarkGray
Write-Host ("代理: {0}" -f $netSel.name) -ForegroundColor DarkGray
Write-Host ("目录: {0}" -f $workingDir) -ForegroundColor DarkGray
try { $Host.UI.RawUI.WindowTitle = ("{0} · {1}" -f $toolSel.name, $netSel.name) } catch { }
Write-Host ("启动 {0}（{1}）" -f $toolSel.name, $netSel.name) -ForegroundColor Yellow

if ($DryRun) {
    Write-Host ("[DryRun] WORKING_DIR={0}" -f $workingDir)
    Write-Host ("[DryRun] {0} {1}" -f $exe, ($toolArgs -join ' | '))
    Write-Host ("[DryRun] HTTP_PROXY={0}" -f $env:HTTP_PROXY)
    exit 0
}

& $exe @toolArgs
exit $LASTEXITCODE
