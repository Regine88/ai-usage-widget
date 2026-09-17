# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetPalette.ps1
# 调色板是纯数据，这里离线校验主题解析、键集合与对比度，避免出现「换了主题只有一半界面变色」。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'WidgetPalette.ps1')

$failed = 0
function Assert-Eq {
    param($Actual, $Expected, [string]$Name)
    if ("$Actual" -ne "$Expected") {
        Write-Host ("FAIL {0}: expected [{1}] got [{2}]" -f $Name, $Expected, $Actual)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}

function Assert-True {
    param($Condition, [string]$Name)
    if (-not $Condition) {
        Write-Host ("FAIL {0}" -f $Name)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}

# 感知亮度，用来粗略检查前景色是否真的能从背景色里看出来。
function Get-Luminance {
    param($Rgb)
    return ((0.2126 * $Rgb[0]) + (0.7152 * $Rgb[1]) + (0.0722 * $Rgb[2])) / 255.0
}

# ---------- 主题解析 ----------
Assert-Eq (ConvertTo-WidgetTheme 'dark') 'dark' 'dark is accepted'
Assert-Eq (ConvertTo-WidgetTheme 'light') 'light' 'light is accepted'
Assert-Eq (ConvertTo-WidgetTheme 'Light') 'light' 'theme names are case insensitive'
Assert-Eq (ConvertTo-WidgetTheme ' dark ') 'dark' 'theme names are trimmed'
Assert-Eq (ConvertTo-WidgetTheme 'neon') 'dark' 'an unknown theme falls back to dark'
Assert-Eq (ConvertTo-WidgetTheme '') 'dark' 'an empty theme falls back to dark'
Assert-Eq (ConvertTo-WidgetTheme $null) 'dark' 'a null theme falls back to dark'
Assert-Eq (ConvertTo-WidgetTheme 'neon' 'light') 'light' 'an explicit default is honored'

# ---------- 键集合 ----------
$dark = Get-WidgetPalette 'dark'
$light = Get-WidgetPalette 'light'
Assert-Eq $dark.Count 13 'dark palette size'
Assert-Eq $light.Count 13 'light palette size'
$darkKeys = @($dark.Keys | Sort-Object)
$lightKeys = @($light.Keys | Sort-Object)
Assert-Eq (($darkKeys -join ',') -eq ($lightKeys -join ',')) 'True' 'both themes expose the same keys'
$expected = @('Background', 'Button', 'Danger', 'Dim', 'ErrorText', 'Field', 'Link', 'Muted', 'Ok', 'Success', 'Text', 'Track', 'Warning') | Sort-Object
Assert-Eq (($darkKeys -join ',') -eq ($expected -join ',')) 'True' 'the palette carries the documented key set'
Assert-Eq (((Get-WidgetPalette 'LIGHT')['Background']) -join ',') '250,250,252' 'an upper-case theme name resolves to the light palette'

# ---------- 取值 ----------
$badShape = @()
foreach ($theme in @('dark', 'light')) {
    $palette = Get-WidgetPalette $theme
    foreach ($key in $palette.Keys) {
        $rgb = @($palette[$key])
        if ($rgb.Count -ne 3) { $badShape += "$theme/$key count"; continue }
        foreach ($channel in $rgb) {
            if ($channel -isnot [int] -and $channel -isnot [long]) { $badShape += "$theme/$key type" }
            elseif ($channel -lt 0 -or $channel -gt 255) { $badShape += "$theme/$key range" }
        }
    }
}
Assert-Eq ($badShape -join ',') '' 'every colour is an in-range RGB triple'

# 两套主题的每个键都必须真的不同：相同就意味着复制粘贴时留下了一个「浅色里还是深色值」的漏网项。
$shared = @()
foreach ($key in $darkKeys) {
    if (($dark[$key] -join ',') -eq ($light[$key] -join ',')) { $shared += $key }
}
Assert-Eq ($shared -join ',') '' 'no colour is shared between the two themes'

# ---------- 对比度 ----------
foreach ($theme in @('dark', 'light')) {
    $palette = Get-WidgetPalette $theme
    $bg = Get-Luminance $palette['Background']
    foreach ($key in @('Text', 'Muted', 'Dim')) {
        $delta = [Math]::Abs((Get-Luminance $palette[$key]) - $bg)
        Assert-True ($delta -ge 0.2) ("{0}: {1} stands out against the background ({2:0.00})" -f $theme, $key, $delta)
    }
    foreach ($key in @('Ok', 'Warning', 'Danger', 'Link')) {
        $delta = [Math]::Abs((Get-Luminance $palette[$key]) - $bg)
        Assert-True ($delta -ge 0.15) ("{0}: {1} stands out against the background ({2:0.00})" -f $theme, $key, $delta)
    }
    # 进度条槽比背景稍深/稍浅即可，完全同色会让空进度条看不见。
    $track = Get-Luminance $palette['Track']
    Assert-True ([Math]::Abs($track - $bg) -ge 0.02) ("{0}: the bar track is visible against the background" -f $theme)
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0