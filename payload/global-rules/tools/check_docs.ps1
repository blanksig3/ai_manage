param(
    [string]$ProjectRoot = '',
    [string]$AsOf = '',
    [switch]$SkipStateCheck,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 单一正文注册表：这些标题的正文只允许存在于指定文件，其余位置只能链接引用。
$script:CanonicalSections = @{
    '任务设计清单' = 'memory/01_任务设计与联动.md'
    '最终完成清单' = 'memory/03_验证与完成.md'
    '浏览器连接与采集回退' = 'memory/07_子代理与工具.md'
}

# 已被取代的词表，出现即报错，防止术语分叉复发。
$script:BannedPhrases = @(
    @{ Pattern = '语法、单元、集成'
       Reason  = '旧验证词表；统一使用「静态 / 针对性 / 联动 / 回归 / 真机」（memory/03）' }
)

function Get-VisibleMarkdown([string]$Content) {
    $out = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    $fenceChar = ''
    $fenceLength = 0
    $inList = $false
    foreach ($line in [regex]::Split($Content, '\r?\n')) {
        $m = [regex]::Match($line, '^\s{0,3}(?<f>`{3,}|~{3,})')
        if ($m.Success) {
            $mark = $m.Groups['f'].Value
            if (-not $inFence) {
                $inFence = $true
                $fenceChar = $mark.Substring(0, 1)
                $fenceLength = $mark.Length
                continue
            }
            if ($mark.Substring(0, 1) -eq $fenceChar -and $mark.Length -ge $fenceLength -and
                $line -match '^\s{0,3}(`{3,}|~{3,})\s*$') {
                $inFence = $false
                continue
            }
        }
        if ($inFence) { continue }

        # 缩进代码块不能中断列表：列表里的 4 空格/Tab 缩进是列表续行，不是代码。
        # 只有不在列表上下文中时，缩进行才按缩进代码块跳过。
        $isBlank = [string]::IsNullOrWhiteSpace($line)
        $isListItem = $line -match '^[ \t]{0,8}(?:[-*+]|\d{1,9}[.)])[ \t]'
        $isIndented = $line -match '^(?: {4}|\t)'
        if (-not $isBlank) {
            if ($isListItem) { $inList = $true }
            elseif (-not $isIndented) { $inList = $false }
        }
        if ($isIndented -and -not $inList) { continue }

        $clean = [regex]::Replace($line, '`+[^`\r\n]*`+', '')
        $out.Add($clean)
    }
    return ($out -join "`n")
}

function ConvertTo-AnchorSlug([string]$Text) {
    $s = [regex]::Replace($Text, '<[^>]+>', '')
    $s = [System.Net.WebUtility]::HtmlDecode($s).ToLowerInvariant().Trim()
    $s = [regex]::Replace($s, '[^\p{L}\p{Nd}\s_-]', '')
    $s = [regex]::Replace($s, '\s+', '-')
    return $s.Trim('-')
}

function Get-HeadingList([string]$Content) {
    $visible = Get-VisibleMarkdown $Content
    $lines = [regex]::Split($visible, '\r?\n')
    $headings = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $atx = [regex]::Match($lines[$i], '^\s{0,3}#{1,6}\s+(?<h>.+?)\s*#*\s*$')
        if ($atx.Success) { $headings.Add($atx.Groups['h'].Value.Trim()); continue }
        if ($i -gt 0 -and $lines[$i] -match '^\s{0,3}(?:=+|-+)\s*$' -and $lines[$i - 1].Trim()) {
            $headings.Add($lines[$i - 1].Trim())
        }
    }
    return ,$headings
}

function Get-AnchorSet([string]$Content) {
    $anchors = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $counts = @{}
    foreach ($heading in (Get-HeadingList $Content)) {
        $base = ConvertTo-AnchorSlug $heading
        if (-not $base) { continue }
        $n = 0
        if ($counts.ContainsKey($base)) { $n = [int]$counts[$base] }
        $slug = if ($n -eq 0) { $base } else { "$base-$n" }
        $counts[$base] = $n + 1
        [void]$anchors.Add($slug)
    }
    $visible = Get-VisibleMarkdown $Content
    foreach ($m in [regex]::Matches($visible,
        '(?i)<a\b[^>]*(?:id|name)\s*=\s*(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<bare>[^\s>]+))')) {
        $id = $m.Groups['dq'].Value
        if (-not $id) { $id = $m.Groups['sq'].Value }
        if (-not $id) { $id = $m.Groups['bare'].Value }
        if ($id) { [void]$anchors.Add([System.Net.WebUtility]::HtmlDecode($id)) }
    }
    return ,$anchors
}

function Get-MarkdownTargets(
    [string]$Content,
    [string]$FilePath,
    [System.Collections.Generic.List[string]]$ParseErrors
) {
    $visible = Get-VisibleMarkdown $Content
    $targets = [System.Collections.Generic.List[string]]::new()
    $refs = @{}

    foreach ($m in [regex]::Matches($visible,
        '(?m)^\s{0,3}\[(?<id>[^\]\r\n]+)\]:\s*(?<target><[^>\r\n]+>|\S+)')) {
        $refs[$m.Groups['id'].Value.Trim().ToLowerInvariant()] = $m.Groups['target'].Value.Trim()
    }

    $inlinePattern = '(?<!\!)\[[^\]\r\n]*\]\((?<target><[^>\r\n]+>|(?:\\.|[^()\r\n]|\([^()\r\n]*\))+)(?:\s+(?:"[^"]*"|''[^'']*''|\([^)]*\)))?\)'
    $inlineMatches = [regex]::Matches($visible, $inlinePattern)
    foreach ($m in $inlineMatches) {
        $targets.Add($m.Groups['target'].Value.Trim())
    }
    foreach ($candidate in [regex]::Matches($visible, '(?<!\!)\[[^\]\r\n]*\]\(')) {
        $covered = $false
        foreach ($m in $inlineMatches) {
            if ($candidate.Index -ge $m.Index -and $candidate.Index -lt ($m.Index + $m.Length)) {
                $covered = $true
                break
            }
        }
        if (-not $covered) {
            $ParseErrors.Add("$FilePath -> unsupported or malformed inline link near index $($candidate.Index)")
        }
    }

    foreach ($m in [regex]::Matches($visible,
        '(?<!\!)\[(?<text>[^\]\r\n]+)\]\[(?<id>[^\]\r\n]*)\]')) {
        $id = $m.Groups['id'].Value.Trim()
        if (-not $id) { $id = $m.Groups['text'].Value.Trim() }
        $key = $id.ToLowerInvariant()
        if ($refs.ContainsKey($key)) { $targets.Add([string]$refs[$key]) }
        else { $ParseErrors.Add("$FilePath -> missing reference definition [$id]") }
    }

    foreach ($m in [regex]::Matches($visible,
        '(?i)<a\b[^>]*href\s*=\s*(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<bare>[^\s>]+))')) {
        $target = $m.Groups['dq'].Value
        if (-not $target) { $target = $m.Groups['sq'].Value }
        if (-not $target) { $target = $m.Groups['bare'].Value }
        if ($target) { $targets.Add([System.Net.WebUtility]::HtmlDecode($target)) }
    }
    return $targets
}

function Test-WithinRoot([string]$Path, [string]$Root) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $base = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $full.Equals($base, [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($base + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsoDate([string]$Value, [ref]$Parsed) {
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Value, 'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$dt)
    $Parsed.Value = $dt
    return $ok
}

function Get-StateRows([string]$Text) {
    $visible = Get-VisibleMarkdown $Text
    return ,([regex]::Matches($visible,
        '(?m)^- 最近验证：(?<md>\d+) 个 Markdown、(?<links>\d+) 个本地链接、死链 (?<dead>\d+)、排除入口后孤儿 (?<orphans>\d+)、[^\r\n]*$'))
}

function Invoke-DocsCheck([string]$Root, [bool]$SkipState, [datetime]$AsOfDate) {
    # Resolve-Path 保留调用者传入的 8.3 短名与 . 段，而 Get-ChildItem().FullName 总是规范长名，
    # 两种写法直接比较永不相等。统一用 Get-Item 规范化根路径，使全部路径比较基于同一形式。
    $projectRoot = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\', '/')
    $markdownFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*.md')
    $stateFile = Join-Path $projectRoot 'STATE.md'
    $requiredFrontmatter = @('scope', 'status', 'owner', 'created', 'updated', 'review_after', 'source')
    $allowedStatus = @('active', 'deprecated', 'conflict', 'archived')

    $rootReadmeKey = ''
    $rootReadmePath = Join-Path $projectRoot 'README.md'
    if (Test-Path -LiteralPath $rootReadmePath -PathType Leaf) {
        $rootReadmeKey = (Get-Item -LiteralPath $rootReadmePath).FullName.ToLowerInvariant()
    }

    $inbound = @{}
    foreach ($file in $markdownFiles) { $inbound[$file.FullName.ToLowerInvariant()] = 0 }

    $localLinkCount = 0
    $deadLinks = [System.Collections.Generic.List[string]]::new()
    $parseErrors = [System.Collections.Generic.List[string]]::new()
    $anchorCache = @{}

    foreach ($file in $markdownFiles) {
        $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $targets = Get-MarkdownTargets $content $file.FullName $parseErrors
        foreach ($raw in $targets) {
            $target = $raw.Trim()
            if ($target.StartsWith('<') -and $target.EndsWith('>')) {
                $target = $target.Substring(1, $target.Length - 2)
            }
            if (-not $target) { $parseErrors.Add("$($file.FullName) -> empty link target"); continue }
            # Windows 盘符路径也长得像 URI scheme（C:），必须先按绝对本地路径拒绝。
            if ([System.IO.Path]::IsPathRooted($target) -or $target -match '^[A-Za-z]:[\\/]') {
                $deadLinks.Add("$($file.FullName) -> ABSOLUTE_LOCAL_PATH $target")
                continue
            }
            if ($target.StartsWith('//') -or $target -match '^[A-Za-z][A-Za-z0-9+.-]*:') { continue }

            $localLinkCount++
            $hash = $target.IndexOf('#')
            if ($hash -ge 0) {
                $pathPart = $target.Substring(0, $hash)
                $fragment = $target.Substring($hash + 1)
            } else {
                $pathPart = $target
                $fragment = ''
            }
            try {
                $pathPart = [System.Uri]::UnescapeDataString($pathPart)
                $fragment = [System.Uri]::UnescapeDataString($fragment)
            } catch {
                $parseErrors.Add("$($file.FullName) -> malformed percent encoding $target")
                continue
            }

            $resolved = if ($pathPart) {
                [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $pathPart))
            } else { $file.FullName }
            if (-not (Test-WithinRoot $resolved $projectRoot)) {
                $deadLinks.Add("$($file.FullName) -> PATH_OUTSIDE_ROOT $target")
                continue
            }
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                $deadLinks.Add("$($file.FullName) -> $target")
                continue
            }
            $real = (Get-Item -LiteralPath $resolved).FullName
            if (-not (Test-WithinRoot $real $projectRoot)) {
                $deadLinks.Add("$($file.FullName) -> LINK_ESCAPES_ROOT $target")
                continue
            }
            $key = $real.ToLowerInvariant()
            if ($inbound.ContainsKey($key)) { $inbound[$key]++ }

            if ($fragment -and [System.IO.Path]::GetExtension($real).Equals(
                '.md', [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not $anchorCache.ContainsKey($key)) {
                    $targetText = [System.IO.File]::ReadAllText($real, [System.Text.Encoding]::UTF8)
                    $anchorCache[$key] = Get-AnchorSet $targetText
                }
                if (-not $anchorCache[$key].Contains($fragment)) {
                    $deadLinks.Add("$($file.FullName) -> MISSING_ANCHOR $target")
                }
            }
        }
    }

    $orphans = @($inbound.GetEnumerator() | Where-Object {
        $_.Value -eq 0 -and $_.Key -ne $rootReadmeKey
    } | ForEach-Object { $_.Key })

    $frontmatterErrors = [System.Collections.Generic.List[string]]::new()
    $canonicalErrors = [System.Collections.Generic.List[string]]::new()
    $vocabularyErrors = [System.Collections.Generic.List[string]]::new()
    $expiredDocs = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $markdownFiles) {
        $relative = $file.FullName.Substring($projectRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

        # 单一正文：注册表里的标题只允许出现在其权威文件中。
        foreach ($heading in (Get-HeadingList $content)) {
            if ($script:CanonicalSections.ContainsKey($heading)) {
                $owner = $script:CanonicalSections[$heading]
                if ($relative -ne $owner) {
                    $canonicalErrors.Add("${relative}: 标题「$heading」的正文只允许在 $owner，此处应改为链接引用")
                }
            }
        }

        # 术语一致：已被取代的词表出现即报错。
        $visible = Get-VisibleMarkdown $content
        foreach ($banned in $script:BannedPhrases) {
            if ($visible.Contains($banned.Pattern)) {
                $vocabularyErrors.Add("${relative}: 出现已弃用词表「$($banned.Pattern)」—— $($banned.Reason)")
            }
        }

        # frontmatter 受管范围：全库所有 Markdown，入口与模板不再豁免。
        $frontmatter = [regex]::Match($content,
            '\A(?:\uFEFF)?---\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|\z)',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $frontmatter.Success) {
            $frontmatterErrors.Add("${relative}: missing frontmatter")
            continue
        }
        $values = @{}
        foreach ($line in [regex]::Split($frontmatter.Groups['yaml'].Value, '\r?\n')) {
            if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
            $m = [regex]::Match($line, '^(?<key>[A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(?<value>.*)$')
            if (-not $m.Success) {
                $frontmatterErrors.Add("${relative}: malformed frontmatter line $line")
                continue
            }
            $k = $m.Groups['key'].Value
            if ($values.ContainsKey($k)) {
                $frontmatterErrors.Add("${relative}: duplicate $k")
            } else { $values[$k] = $m.Groups['value'].Value.Trim() }
        }
        foreach ($field in $requiredFrontmatter) {
            if (-not $values.ContainsKey($field)) {
                $frontmatterErrors.Add("${relative}: missing $field")
            } elseif (-not [string]$values[$field]) {
                $frontmatterErrors.Add("${relative}: empty $field")
            }
        }
        if ($values.ContainsKey('status') -and $values['status'] -and
            $allowedStatus -notcontains $values['status']) {
            $frontmatterErrors.Add("${relative}: invalid status $($values['status'])")
        }
        $dates = @{}
        foreach ($field in @('created', 'updated', 'review_after')) {
            if ($values.ContainsKey($field) -and $values[$field]) {
                $dt = [datetime]::MinValue
                if (-not (Test-IsoDate $values[$field] ([ref]$dt))) {
                    $frontmatterErrors.Add("${relative}: invalid date $field=$($values[$field])")
                } else { $dates[$field] = $dt }
            }
        }
        if ($dates.ContainsKey('updated') -and $dates.ContainsKey('review_after') -and
            $dates['review_after'] -lt $dates['updated']) {
            $frontmatterErrors.Add("${relative}: review_after earlier than updated")
        }
        # 到期复审只告警不阻塞：日期不应把整条流水线卡死。
        if ($dates.ContainsKey('review_after') -and $dates['review_after'] -lt $AsOfDate) {
            $expiredDocs.Add("${relative}: review_after $($values['review_after']) 早于 $($AsOfDate.ToString('yyyy-MM-dd'))")
        }
    }

    $stateMatches = $SkipState
    if (-not $SkipState) {
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            $stateText = [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8)
            $rows = Get-StateRows $stateText
            $stateMatches = $rows.Count -eq 1 -and
                [int]$rows[0].Groups['md'].Value -eq $markdownFiles.Count -and
                [int]$rows[0].Groups['links'].Value -eq $localLinkCount -and
                [int]$rows[0].Groups['dead'].Value -eq $deadLinks.Count -and
                [int]$rows[0].Groups['orphans'].Value -eq $orphans.Count
        } else { $stateMatches = $false }
    }

    $status = if ($deadLinks.Count -eq 0 -and $orphans.Count -eq 0 -and
        $frontmatterErrors.Count -eq 0 -and $parseErrors.Count -eq 0 -and
        $canonicalErrors.Count -eq 0 -and $vocabularyErrors.Count -eq 0 -and $stateMatches) {
        'PASS'
    } else { 'FAIL' }
    return [pscustomobject]@{
        MarkdownFiles = $markdownFiles.Count
        LocalLinks = $localLinkCount
        DeadLinks = $deadLinks.Count
        OrphansExcludingRootReadme = $orphans.Count
        FrontmatterErrors = $frontmatterErrors.Count
        ParseErrors = $parseErrors.Count
        CanonicalBodyErrors = $canonicalErrors.Count
        VocabularyErrors = $vocabularyErrors.Count
        ExpiredDocs = $expiredDocs.Count
        StateMatches = $stateMatches
        Status = $status
        DeadLinkDetails = $deadLinks
        OrphanDetails = $orphans
        FrontmatterDetails = $frontmatterErrors
        ParseDetails = $parseErrors
        CanonicalDetails = $canonicalErrors
        VocabularyDetails = $vocabularyErrors
        ExpiredDetails = $expiredDocs
    }
}

function Invoke-DocsSelfTest {
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $temp = Join-Path $tempBase ("memory-palace-doccheck-" + [guid]::NewGuid().ToString('N'))
    if (-not (Test-WithinRoot $temp $tempBase)) { throw 'refuse unsafe self-test path' }
    New-Item -ItemType Directory -Path $temp | Out-Null
    $today = [datetime]::Today
    $script:docsSelfTestOk = $true
    function Case([string]$Name, [scriptblock]$Build, [scriptblock]$Assert) {
        $caseRoot = Join-Path $temp $Name
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        & $Build $caseRoot
        $r = Invoke-DocsCheck $caseRoot $true $today
        $good = [bool](& $Assert $r)
        Write-Output "[$(if ($good) {'PASS'} else {'FAIL'})] docs checker 反例: $Name"
        if (-not $good) { Write-Output ($r | Format-List | Out-String) }
        $script:docsSelfTestOk = $script:docsSelfTestOk -and $good
    }
    try {
        Case 'fenced-code' {
            param($p) Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value @'
# Root
```md
[伪链接](missing.md)
```
'@
        } { param($r) $r.DeadLinks -eq 0 -and $r.LocalLinks -eq 0 }

        Case 'reference-link' {
            param($p)
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value "[入口][guide]`n`n[guide]: target.md"
            Set-Content -LiteralPath (Join-Path $p 'target.md') -Encoding UTF8 -Value '# Target'
        } { param($r) $r.DeadLinks -eq 0 -and $r.LocalLinks -eq 1 -and $r.OrphansExcludingRootReadme -eq 0 }

        Case 'bad-anchor' {
            param($p)
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[坏](target.md#missing)'
            Set-Content -LiteralPath (Join-Path $p 'target.md') -Encoding UTF8 -Value '# Existing'
        } { param($r) $r.DeadLinks -eq 1 }

        $outside = Join-Path $temp 'outside.md'
        Set-Content -LiteralPath $outside -Encoding UTF8 -Value '# Outside'
        Case 'outside-root' {
            param($p) Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[越界](../outside.md)'
        } { param($r) $r.DeadLinks -eq 1 }

        Case 'windows-absolute' {
            param($p) Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[绝对](C:/outside.md)'
        } { param($r) $r.DeadLinks -eq 1 -and $r.LocalLinks -eq 0 }

        Case 'deep-parentheses' {
            param($p) Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[复杂](a_(b(c)).md)'
        } { param($r) $r.ParseErrors -eq 1 }

        Case 'html-anchor' {
            param($p)
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '<a href="target.md#模块路由">入口</a>'
            Set-Content -LiteralPath (Join-Path $p 'target.md') -Encoding UTF8 -Value '# 模块路由'
        } { param($r) $r.DeadLinks -eq 0 -and $r.LocalLinks -eq 1 }

        Case 'frontmatter' {
            param($p)
            New-Item -ItemType Directory -Path (Join-Path $p 'memory') | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[m](memory/m.md)'
            Set-Content -LiteralPath (Join-Path $p 'memory/m.md') -Encoding UTF8 -Value @'
---
scope: x
scope: duplicate
status:
owner: x
created: 2026-08-20
updated: bad-date
review_after: 2026-01-01
source: x
---
# M
'@
        } { param($r) $r.FrontmatterErrors -ge 3 }

        # 回归：嵌套列表里的链接曾被整行当作缩进代码块丢弃，死链静默漏检。
        Case 'indented-link' {
            param($p)
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value @"
# Root

[顶格](target.md)

- 列表
    - [四空格](GONE-4SP.md)
`t- [制表符](GONE-TAB.md)
  - [两空格](GONE-2SP.md)
"@
            Set-Content -LiteralPath (Join-Path $p 'target.md') -Encoding UTF8 -Value '# Target'
        } { param($r) $r.LocalLinks -eq 4 -and $r.DeadLinks -eq 3 }

        # 回归：根 README 豁免曾用朴素字符串比较。Resolve-Path 保留传入的 8.3 短名，
        # 而 Get-ChildItem().FullName 展开为长名，两者永不相等，根 README 被误判为孤儿。
        # 只有 8.3 短名能复现（大小写差异会被 ToLowerInvariant 抵消）。
        $shortRoot = Join-Path $temp 'shortname-root'
        New-Item -ItemType Directory -Path $shortRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $shortRoot 'README.md') -Encoding UTF8 -Value '[目标](target.md)'
        Set-Content -LiteralPath (Join-Path $shortRoot 'target.md') -Encoding UTF8 -Value '# Target'
        $shortPath = ''
        try {
            $fso = New-Object -ComObject Scripting.FileSystemObject
            $shortPath = $fso.GetFolder($shortRoot).ShortPath
        } catch { $shortPath = '' }
        if ($shortPath -and $shortPath -ne $shortRoot) {
            $rs = Invoke-DocsCheck $shortPath $true $today
            $shortGood = $rs.OrphansExcludingRootReadme -eq 0
            Write-Output "[$(if ($shortGood) {'PASS'} else {'FAIL'})] docs checker 反例: shortname-root"
            if (-not $shortGood) { Write-Output ($rs | Format-List | Out-String) }
            $script:docsSelfTestOk = $script:docsSelfTestOk -and $shortGood
        } else {
            Write-Output '[SKIP] docs checker 反例: shortname-root（本卷未生成 8.3 短名，无法构造该输入）'
        }

        # 单一正文：注册表内的标题出现在非权威文件即报错。
        Case 'canonical-body' {
            param($p)
            New-Item -ItemType Directory -Path (Join-Path $p 'memory') | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[副本](memory/copy.md)'
            Set-Content -LiteralPath (Join-Path $p 'memory/copy.md') -Encoding UTF8 -Value "# 复制品`n`n## 最终完成清单`n`n1. 复制的正文。"
        } { param($r) $r.CanonicalBodyErrors -eq 1 -and $r.Status -eq 'FAIL' }

        # 权威文件本身持有该标题时不得报错。
        Case 'canonical-owner-ok' {
            param($p)
            New-Item -ItemType Directory -Path (Join-Path $p 'memory') | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[权威](memory/03_验证与完成.md)'
            Set-Content -LiteralPath (Join-Path $p 'memory/03_验证与完成.md') -Encoding UTF8 -Value "# 验证与完成`n`n## 最终完成清单`n`n1. 权威正文。"
        } { param($r) $r.CanonicalBodyErrors -eq 0 }

        # 浏览器回退正文只能归属 07；入口和索引只做链接路由。
        Case 'browser-canonical-copy' {
            param($p)
            New-Item -ItemType Directory -Path (Join-Path $p 'memory') | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[副本](memory/copy.md)'
            Set-Content -LiteralPath (Join-Path $p 'memory/copy.md') -Encoding UTF8 -Value "# 副本`n`n## 浏览器连接与采集回退`n`n重复正文。"
        } { param($r) $r.CanonicalBodyErrors -eq 1 -and $r.Status -eq 'FAIL' }

        Case 'browser-canonical-owner' {
            param($p)
            New-Item -ItemType Directory -Path (Join-Path $p 'memory') | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '[权威](memory/07_子代理与工具.md)'
            Set-Content -LiteralPath (Join-Path $p 'memory/07_子代理与工具.md') -Encoding UTF8 -Value "# 工具`n`n## 浏览器连接与采集回退`n`n权威正文。"
        } { param($r) $r.CanonicalBodyErrors -eq 0 }

        # 术语分叉：已弃用词表出现即报错。
        Case 'banned-vocabulary' {
            param($p)
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value '相关语法、单元、集成检查已执行。'
        } { param($r) $r.VocabularyErrors -eq 1 -and $r.Status -eq 'FAIL' }

        # 弃用词表写在围栏代码块里属于举例，不算违规。
        Case 'banned-in-fence' {
            param($p) Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value @'
# Root
```text
语法、单元、集成
```
'@
        } { param($r) $r.VocabularyErrors -eq 0 }

        # 过期复审只告警，不改变 Status。
        Case 'expired-review' {
            param($p)
            New-Item -ItemType Directory -Path (Join-Path $p 'memory') | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'README.md') -Encoding UTF8 -Value @'
---
scope: root
status: active
owner: u
created: 2020-01-01
updated: 2020-01-01
review_after: 2090-01-01
source: s
---

[过期](memory/old.md)
'@
            Set-Content -LiteralPath (Join-Path $p 'memory/old.md') -Encoding UTF8 -Value @'
---
scope: old
status: active
owner: u
created: 2020-01-01
updated: 2020-01-01
review_after: 2020-06-01
source: s
---

# 旧文件
'@
        } { param($r) $r.ExpiredDocs -eq 1 -and $r.FrontmatterErrors -eq 0 -and $r.Status -eq 'PASS' }

        $stateRows = Get-StateRows "- 普通说明：1 个 Markdown、0 个本地链接、死链 0、排除入口后孤儿 0`n- 最近验证：1 个 Markdown、0 个本地链接、死链 0、排除入口后孤儿 0、x"
        $stateGood = $stateRows.Count -eq 1
        Write-Output "[$(if ($stateGood) {'PASS'} else {'FAIL'})] docs checker 反例: 状态只绑定最近验证行"
        $script:docsSelfTestOk = $script:docsSelfTestOk -and $stateGood

        $fakeState = @'
```text
- 最近验证：1 个 Markdown、0 个本地链接、死链 0、排除入口后孤儿 0、x
```
'@
        $codeStateGood = (Get-StateRows $fakeState).Count -eq 0
        Write-Output "[$(if ($codeStateGood) {'PASS'} else {'FAIL'})] docs checker 反例: 代码块伪状态不生效"
        $script:docsSelfTestOk = $script:docsSelfTestOk -and $codeStateGood
    } finally {
        if ((Test-Path -LiteralPath $temp) -and (Test-WithinRoot $temp $tempBase)) {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
    Write-Output ('=' * 44)
    Write-Output "docs checker 自检: $(if ($script:docsSelfTestOk) {'PASS'} else {'FAIL'})"
    if (-not $script:docsSelfTestOk) { exit 1 }
    exit 0
}

if ($SelfTest) { Invoke-DocsSelfTest }

if (-not $ProjectRoot) {
    $ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
$asOfDate = [datetime]::Today
if ($AsOf) {
    $parsed = [datetime]::MinValue
    if (-not (Test-IsoDate $AsOf ([ref]$parsed))) { throw "AsOf 需为 yyyy-MM-dd，收到：$AsOf" }
    $asOfDate = $parsed
}
$result = Invoke-DocsCheck $ProjectRoot ([bool]$SkipStateCheck) $asOfDate
$result | Select-Object MarkdownFiles, LocalLinks, DeadLinks, OrphansExcludingRootReadme,
    FrontmatterErrors, ParseErrors, CanonicalBodyErrors, VocabularyErrors, ExpiredDocs,
    StateMatches, Status | Format-List
if ($result.DeadLinks -gt 0) { $result.DeadLinkDetails }
if ($result.OrphansExcludingRootReadme -gt 0) {
    $result.OrphanDetails | ForEach-Object { "Orphan: $_" }
}
if ($result.FrontmatterErrors -gt 0) { $result.FrontmatterDetails }
if ($result.ParseErrors -gt 0) { $result.ParseDetails }
if ($result.CanonicalBodyErrors -gt 0) { $result.CanonicalDetails }
if ($result.VocabularyErrors -gt 0) { $result.VocabularyDetails }
if ($result.ExpiredDocs -gt 0) { $result.ExpiredDetails | ForEach-Object { "WARN 复审到期: $_" } }
if ($result.Status -ne 'PASS') { exit 1 }
