# Encoding: UTF-8 with BOM.
# WidgetStrings.ps1 - 界面文案的语言包加载与查询。
#
# 设计：
#  - 语言包是 strings/<language>.json，键值都是字符串，值里可以用 {0} 这类占位符。
#  - 任何异常都不允许影响界面：读不到文件时回退到内置兜底表，缺键时返回键名本身。
#  - Get-WidgetText 是纯函数，主进程与后台 worker 共用同一张表（worker 通过 $Cfg 拿到）。

$script:WidgetStringLanguages = @('zh-CN', 'en-US')

# 兜底表只覆盖最关键的文案，保证语言包文件缺失时界面仍然可用可读。
$script:WidgetStringFallback = @{
    'app.title'            = 'AI Usage Widget'
    'app.trayTip'          = 'AI Usage Widget'
    'menu.refresh'         = 'Refresh now'
    'menu.export'          = 'Export history'
    'menu.settings'        = 'Settings...'
    'menu.quit'            = 'Quit'
    'status.noCredentials' = 'No credentials found'
    'status.startFailed'   = 'Refresh failed'
    'status.refreshing'    = 'Refreshing...'
    'reset.unknown'        = 'Reset time unknown'
    'error.generic'        = 'Failed to read usage'
    'error.noCredentials'  = 'Not signed in'
    'error.planMissing'    = 'This account has no Coding Plan'
    'error.timeout'        = 'Request timed out'
    'error.network'        = 'Network connection failed'
    'error.unauthorized'   = 'Sign-in expired, please sign in again'
    'tip.openUsage'        = 'Double-click to open the usage page'
    'settings.title'       = 'AI Usage Widget - Settings'
    'settings.save'        = 'Save'
    'settings.cancel'      = 'Cancel'
    'csv.exported'         = 'Exported to {0}{1}'
}

function ConvertTo-WidgetLanguage {
    param([string]$Value, [string]$CultureName)
    if ($Value -and $Value -ne 'auto') {
        foreach ($item in $script:WidgetStringLanguages) {
            if ($item -eq $Value) { return $item }
        }
        if ($Value -like 'zh*') { return 'zh-CN' }
        if ($Value -like 'en*') { return 'en-US' }
    }
    $culture = $CultureName
    if (-not $culture) { $culture = [Globalization.CultureInfo]::CurrentUICulture.Name }
    if ($culture -like 'zh*') { return 'zh-CN' }
    return 'en-US'
}

function Get-WidgetStringsDir {
    param([string]$Dir)
    if ($Dir) { return (Join-Path $Dir 'strings') }
    if ($PSScriptRoot) { return (Join-Path $PSScriptRoot 'strings') }
    if ($script:WidgetDir) { return (Join-Path $script:WidgetDir 'strings') }
    return (Join-Path (Get-Location).Path 'strings')
}

function Get-WidgetStringsPath {
    param([string]$Language, [string]$Dir)
    $resolved = ConvertTo-WidgetLanguage $Language
    return (Join-Path (Get-WidgetStringsDir $Dir) ($resolved + '.json'))
}

function ConvertTo-WidgetStringTable {
    param($Raw)
    $table = @{}
    if (-not $Raw) { return $table }
    foreach ($prop in $Raw.PSObject.Properties) {
        if ($prop.Name -like '_*') { continue }
        if ($null -eq $prop.Value) { continue }
        $table[$prop.Name] = [string]$prop.Value
    }
    return $table
}

function Get-WidgetStringFallback {
    $copy = @{}
    foreach ($key in $script:WidgetStringFallback.Keys) { $copy[$key] = $script:WidgetStringFallback[$key] }
    return $copy
}

function Read-WidgetStrings {
    param([string]$Language, [string]$Dir)
    $table = Get-WidgetStringFallback
    $path = Get-WidgetStringsPath -Language $Language -Dir $Dir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $table }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        $loaded = ConvertTo-WidgetStringTable $raw
        foreach ($key in $loaded.Keys) { $table[$key] = $loaded[$key] }
    } catch {
        if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
            Write-WidgetLog ('strings ignored: {0}' -f (Convert-SafeLogText $_.Exception.Message))
        }
    }
    return $table
}

function Get-WidgetText {
    param(
        [string]$Key,
        $Arguments,
        $Table
    )
    if (-not $Table) { $Table = $script:WidgetStrings }
    $text = $null
    if ($Table -and $Table.ContainsKey($Key)) { $text = [string]$Table[$Key] }
    if (-not $text) { $text = $Key }
    if ($null -ne $Arguments) {
        try {
            if (@($Arguments).Count -gt 0) { return ($text -f $Arguments) }
        } catch {
            return $text
        }
    }
    return $text
}

# 供 worker 与主进程共用的简写；$script:WidgetStrings 必须已赋值。
function T {
    param([string]$Key, $Arguments)
    return (Get-WidgetText -Key $Key -Arguments $Arguments)
}
