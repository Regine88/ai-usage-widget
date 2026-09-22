# Encoding: UTF-8 with BOM.
# 发布包内容校验：把“应该打包哪些文件”“压缩包里实际有什么”“Scoop manifest 写得对不对”
# 三件事拆成纯函数，tools/verify-package.ps1 与离线测试共用同一套规则。
#
# 纯函数不读盘；只有 Read-WidgetZipEntryNames / Read-WidgetZipEntryText 访问压缩包。

# 这些文件属于运行期数据或凭证，绝不能出现在发布包里。
$script:WidgetPackageForbiddenNames = @(
    'ai-config.json'
    'ai-state.json'
    'ai-history.jsonl'
    'ai-request-events.jsonl'
    'ai-widget.log'
    'grok-aliases.json'
    'state.vscdb'
    'state.vscdb.backup'
    '*.log'
    '*.env'
    '.env*'
    'credentials*'
    '*credential*.json'
    '*token*.json'
    '*.db'
    '*.sqlite'
    '*.bak'
    '*.tmp'
)

$script:WidgetPackageExtraFiles = @('install.ps1', 'LICENSE', 'README.md', 'README.en.md', 'CHANGELOG.md')

function Get-WidgetPackageExtraFiles {
    return @($script:WidgetPackageExtraFiles)
}

# 只按文件名判断（压缩包里带目录），命中即视为不可发布。
function Test-WidgetPackageForbiddenEntry {
    param([string]$Name)
    if (-not $Name) { return $false }
    $leaf = [IO.Path]::GetFileName(([string]$Name).Replace('\', '/'))
    foreach ($pattern in $script:WidgetPackageForbiddenNames) {
        if ($leaf -like $pattern) { return $true }
    }
    return $false
}

# 仓库里的相对路径可能带反斜杠（子目录），压缩包条目一律是正斜杠，这里统一。
function Get-WidgetPackageExpectedEntries {
    param($Runtime, $Extra)
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Runtime) + @($Extra)) {
        if (-not $item) { continue }
        [void]$entries.Add(([string]$item).Replace('\', '/'))
    }
    return @($entries | Sort-Object -Unique)
}

# 目录里的条目都带一层包名（Compress-Archive 把 stage 目录一起打进去），
# 比较前先剥掉这层前缀，剩下的是仓库里的相对路径。
function ConvertTo-WidgetPackageRelativeEntry {
    param([string]$Name, [string]$Prefix)
    if (-not $Name) { return '' }
    $normalized = ([string]$Name).Replace('\', '/').TrimStart('/')
    if ($Prefix) {
        $clean = $Prefix.Replace('\', '/').Trim('/') + '/'
        if ($normalized.StartsWith($clean, [StringComparison]::OrdinalIgnoreCase)) {
            $normalized = $normalized.Substring($clean.Length)
        }
    }
    return $normalized
}

function Compare-WidgetPackageEntries {
    param($Expected, $Actual, [string]$Prefix)
    $expectedSet = @{}
    foreach ($item in @($Expected)) { if ($item) { $expectedSet[[string]$item] = $true } }
    $actualSet = @{}
    $forbidden = @()
    foreach ($item in @($Actual)) {
        $relative = ConvertTo-WidgetPackageRelativeEntry -Name $item -Prefix $Prefix
        if (-not $relative) { continue }
        if ($relative.EndsWith('/')) { continue }
        # 数据/凭证文件单独归类，不再重复计入“多余文件”。
        if (Test-WidgetPackageForbiddenEntry $relative) {
            $forbidden += $relative
            continue
        }
        $actualSet[$relative] = $true
    }
    $missing = @($expectedSet.Keys | Where-Object { -not $actualSet.ContainsKey($_) } | Sort-Object)
    $extra = @($actualSet.Keys | Where-Object { -not $expectedSet.ContainsKey($_) } | Sort-Object)
    return @{
        Missing   = $missing
        Extra     = $extra
        Forbidden = @($forbidden | Sort-Object -Unique)
    }
}

function Test-WidgetPackageVersionText {
    param([string]$Text, [string]$Version)
    if (-not $Text -or -not $Version) { return $false }
    # 用 Escape 拼模式，避免 $script: 被当成变量插值。
    $pattern = [regex]::Escape('$script:AppVersion') + "\s*=\s*'" + [regex]::Escape($Version) + "'"
    return [bool](([string]$Text) -match $pattern)
}

# Scoop manifest 的三处关键字段必须和实际产物一致，否则装机时校验会失败。
function Get-WidgetPackageManifestProblems {
    param($Manifest, [string]$Version, [string]$Hash, [string]$ZipName, [string]$Repo)
    $problems = @()
    if (-not $Manifest) { return @('manifest is missing') }
    if ([string]$Manifest.version -ne $Version) { $problems += ('manifest version is ' + [string]$Manifest.version) }
    if ([string]$Manifest.hash -ne $Hash) { $problems += 'manifest hash does not match the zip' }
    if ($ZipName -and ([string]$Manifest.url -notlike ('*' + $ZipName))) { $problems += 'manifest url does not point at the zip' }
    if ($Version -and ([string]$Manifest.url -notlike ('*/v' + $Version + '/*'))) { $problems += 'manifest url does not carry the tag' }
    if ([string]$Manifest.extract_dir -ne [IO.Path]::GetFileNameWithoutExtension($ZipName)) {
        $problems += 'manifest extract_dir does not match the archive'
    }
    if ($Repo -and ([string]$Manifest.checkver.github -notlike ('*' + $Repo + '*'))) { $problems += 'manifest checkver does not point at the repo' }
    $persist = @($Manifest.persist)
    foreach ($expected in @('ai-config.json', 'ai-history.jsonl', 'ai-state.json', 'history')) {
        if ($persist -notcontains $expected) { $problems += ('manifest persist is missing ' + $expected) }
    }
    return @($problems)
}

function Test-WidgetPackageZipSupport {
    if ('System.IO.Compression.ZipFile' -as [type]) { return $true }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    return [bool]('System.IO.Compression.ZipFile' -as [type])
}

function Read-WidgetZipEntryNames {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    if (-not (Test-WidgetPackageZipSupport)) { throw 'zip support is unavailable' }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $archive.Entries) { [void]$names.Add($entry.FullName) }
        return @($names.ToArray())
    } finally {
        $archive.Dispose()
    }
}

function Read-WidgetZipEntryText {
    param([string]$Path, [string]$EntryName)
    if (-not $Path -or -not $EntryName -or -not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-WidgetPackageZipSupport)) { throw 'zip support is unavailable' }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            $normalized = $entry.FullName.Replace('\', '/')
            if ($normalized -ne ([string]$EntryName).Replace('\', '/')) { continue }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        return $null
    } finally {
        $archive.Dispose()
    }
}
