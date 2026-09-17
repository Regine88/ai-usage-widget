# Encoding: UTF-8 with BOM.
# 趋势图：把 ai-history.jsonl 的采样点整理成可绘制的折线数据。
#
# 全部是纯函数：不读盘、不联网、不建窗口。读历史交给 UsageHistory.ps1，
# 绘制交给主程序，所以这里可以直接离线测试。模块内不使用界面文案助手，
# 图例与坐标轴文字由调用方格式化。

if (-not (Get-Command ConvertTo-UsageHistoryArray -ErrorAction SilentlyContinue)) {
    $historyHelper = Join-Path $PSScriptRoot 'UsageHistory.ps1'
    if (Test-Path -LiteralPath $historyHelper) { . $historyHelper }
}

# 用量一律按 0 - 100 百分比绘制：供应商之间、天数之间可以直接对比，
# 不会因为某一条曲线自己的波动把纵轴拉偏。
$script:UsageTrendChartMin = 0.0
$script:UsageTrendChartMax = 100.0

function Get-UsageTrendChartRange {
    return @{ Min = [double]$script:UsageTrendChartMin; Max = [double]$script:UsageTrendChartMax }
}

# 纵轴刻度：默认 0 / 25 / 50 / 75 / 100，从高到低由调用方自行决定绘制顺序。
function Get-UsageTrendChartTicks {
    param([double]$Min = 0, [double]$Max = 100, [int]$Count = 5)
    if ($Max -le $Min) { return @($Min) }
    if ($Count -lt 2) { return @($Min) }
    $step = ($Max - $Min) / ($Count - 1)
    $ticks = @()
    for ($i = 0; $i -lt $Count; $i++) { $ticks += [Math]::Round($Min + $step * $i, 4) }
    return $ticks
}

# 折线坐标：X 按“距起始日的天数”定位，所以没有采样的日子直接留出空档，
# 不会把两天的缺口压成一个点；Y 与 WinForms 一致，向下为正。
function Get-UsageTrendChartPoints {
    param(
        $Series,
        [datetime]$StartDay,
        [int]$Days,
        [double]$Width,
        [double]$Height,
        [double]$Pad = 0,
        [double]$Min = 0,
        [double]$Max = 100
    )
    $points = @(ConvertTo-UsageHistoryArray $Series)
    if ($points.Count -lt 1 -or $Days -lt 2 -or $Width -le 0 -or $Height -le 0) { return @() }
    if ($Max -le $Min) { return @() }
    $innerW = [Math]::Max(0.0, $Width - 2 * $Pad)
    $innerH = [Math]::Max(0.0, $Height - 2 * $Pad)
    $start = $StartDay.Date
    $result = @()
    foreach ($point in $points) {
        if (-not $point) { continue }
        $day = $point.Day
        if (-not ($day -is [datetime])) { continue }
        $offset = ($day.Date - $start).Days
        if ($offset -lt 0 -or $offset -gt ($Days - 1)) { continue }
        $ratio = ([double]$point.Pct - $Min) / ($Max - $Min)
        $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $ratio))
        $result += @{
            X = $Pad + $innerW * $offset / ($Days - 1)
            Y = $Pad + $innerH * (1.0 - $ratio)
        }
    }
    return $result
}

# 横轴日期标签：在区间上均匀取几个点，返回 Offset 与对应日期，
# 由调用方决定怎么格式化（模块不产出面向用户的文字）。
function Get-UsageTrendChartDayLabels {
    param([datetime]$StartDay, [int]$Days, [int]$Count = 4)
    if ($Days -lt 1) { return @() }
    if ($Count -lt 1) { $Count = 1 }
    if ($Count -gt $Days) { $Count = $Days }
    $start = $StartDay.Date
    if ($Count -eq 1) { return @(@{ Offset = ($Days - 1); Day = $start.AddDays($Days - 1) }) }
    $labels = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $offset = [int][Math]::Round(($Days - 1) * $i / ($Count - 1))
        $labels += @{ Offset = $offset; Day = $start.AddDays($offset) }
    }
    return $labels
}

# 序列的最后一个百分比，用于图例；空序列返回 $null。
function Get-UsageTrendLatestPercent {
    param($Series)
    $points = @(ConvertTo-UsageHistoryArray $Series)
    if ($points.Count -lt 1) { return $null }
    $last = $points[$points.Count - 1]
    if (-not $last) { return $null }
    try { return [double]$last.Pct } catch { return $null }
}

# 把多组序列整理成一份绘图模型：坐标、图例用的名称与最新值。
# 在窗口区间内没有任何采样的供应商会被跳过，避免出现只有图例的空白项。
function Get-UsageTrendChartModel {
    param($Entries, [datetime]$StartDay, [int]$Days, [double]$Width, [double]$Height, [double]$Pad = 0)
    $range = Get-UsageTrendChartRange
    $model = @()
    foreach ($entry in @(ConvertTo-UsageHistoryArray $Entries)) {
        if (-not $entry) { continue }
        $points = @(Get-UsageTrendChartPoints -Series $entry.Series -StartDay $StartDay -Days $Days -Width $Width -Height $Height -Pad $Pad -Min $range.Min -Max $range.Max)
        if ($points.Count -lt 1) { continue }
        $model += @{
            Id     = [string]$entry.Id
            Name   = [string]$entry.Name
            Latest = (Get-UsageTrendLatestPercent $entry.Series)
            Points = $points
        }
    }
    return $model
}

# Demo 模式的合成序列：确定性生成 N 天数据，最后一天正好等于该行的当前用量，
# 这样 -Demo 与 -Demo -TrendWindow 都不需要真实历史。
function New-UsageTrendDemoSeries {
    param([double]$EndPct, [int]$Days = 30, [datetime]$EndDay = (Get-Date))
    if ($Days -lt 1) { return @() }
    $series = @()
    for ($i = 0; $i -lt $Days; $i++) {
        $age = $Days - 1 - $i
        $value = $EndPct - ($age * 1.7) + ([Math]::Sin($age / 2.0) * 2.5)
        $value = [Math]::Max(0.0, [Math]::Min(100.0, $value))
        $series += @{ Day = $EndDay.Date.AddDays(-$age); Pct = [Math]::Round($value, 2) }
    }
    return $series
}
