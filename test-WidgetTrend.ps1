# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetTrend.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'UsageHistory.ps1')
. (Join-Path $here 'WidgetTrend.ps1')

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

function New-Point {
    param([string]$Day, [double]$Pct)
    return @{ Day = [datetime]::ParseExact($Day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); Pct = $Pct }
}

function Get-Rounded {
    param($Value, [int]$Digits = 4)
    return [Math]::Round([double]$Value, $Digits)
}

# ---------- 坐标轴范围与刻度 ----------
$range = Get-UsageTrendChartRange
Assert-Eq $range.Min 0 'range starts at zero'
Assert-Eq $range.Max 100 'range ends at a full percentage'
Assert-Eq ((Get-UsageTrendChartTicks) -join ',') '0,25,50,75,100' 'default ticks are quarters'
Assert-Eq ((Get-UsageTrendChartTicks -Min 0 -Max 100 -Count 3) -join ',') '0,50,100' 'tick count is configurable'
Assert-Eq ((Get-UsageTrendChartTicks -Min 40 -Max 40) -join ',') '40' 'a flat range yields the single value'
Assert-Eq ((Get-UsageTrendChartTicks -Min 0 -Max 100 -Count 1) -join ',') '0' 'a single tick is the minimum'

# ---------- 折线坐标 ----------
$one = @(New-Point '2026-09-01' 0)
$points = @(Get-UsageTrendChartPoints -Series $one -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50)
Assert-Eq $points.Count 1 'a single sample still produces a point'
Assert-Eq (Get-Rounded $points[0].X) 0 'the first day sits on the left edge'
Assert-Eq (Get-Rounded $points[0].Y) 50 'zero percent sits at the bottom'

$top = @(Get-UsageTrendChartPoints -Series @(New-Point '2026-09-01' 100) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50)
Assert-Eq (Get-Rounded $top[0].Y) 0 'a full percentage sits at the top'

$middle = @(Get-UsageTrendChartPoints -Series @(New-Point '2026-09-04' 50) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50)
Assert-Eq (Get-Rounded $middle[0].X) 50 'x follows the day offset, not the index'
Assert-Eq (Get-Rounded $middle[0].Y) 25 'fifty percent sits in the middle'

$padded = @(Get-UsageTrendChartPoints -Series @(New-Point '2026-09-04' 100) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50 -Pad 5)
Assert-Eq (Get-Rounded $padded[0].X) 50 'padding keeps the inner width'
Assert-Eq (Get-Rounded $padded[0].Y) 5 'padding keeps the inner height'

$clamped = @(Get-UsageTrendChartPoints -Series @((New-Point '2026-09-01' 140), (New-Point '2026-09-02' -5)) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50)
Assert-Eq (Get-Rounded $clamped[0].Y) 0 'values above the range clamp to the top'
Assert-Eq (Get-Rounded $clamped[1].Y) 50 'values below the range clamp to the bottom'

$outside = @(Get-UsageTrendChartPoints -Series @((New-Point '2026-08-31' 10), (New-Point '2026-09-08' 20)) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50)
Assert-Eq $outside.Count 0 'samples outside the window are dropped'

$gap = @(Get-UsageTrendChartPoints -Series @((New-Point '2026-09-01' 10), (New-Point '2026-09-07' 20)) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 60 -Height 50)
Assert-Eq (Get-Rounded $gap[1].X) 60 'missing days leave a real gap instead of closing it'

Assert-Eq (@(Get-UsageTrendChartPoints -Series @() -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50).Count) 0 'an empty series has no points'
Assert-Eq (@(Get-UsageTrendChartPoints -Series $one -StartDay ([datetime]'2026-09-01') -Days 1 -Width 100 -Height 50).Count) 0 'a single day window has no line'
Assert-Eq (@(Get-UsageTrendChartPoints -Series $one -StartDay ([datetime]'2026-09-01') -Days 7 -Width 0 -Height 50).Count) 0 'zero width has no points'
Assert-Eq (@(Get-UsageTrendChartPoints -Series $one -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 0).Count) 0 'zero height has no points'
Assert-Eq (@(Get-UsageTrendChartPoints -Series @(New-Point '2026-09-01' 10) -StartDay ([datetime]'2026-09-01') -Days 7 -Width 100 -Height 50 -Min 50 -Max 50).Count) 0 'a degenerate range has no points'

# ---------- 日期标签 ----------
$labels = @(Get-UsageTrendChartDayLabels -StartDay ([datetime]'2026-09-01') -Days 30 -Count 4)
Assert-Eq $labels.Count 4 'four labels by default'
Assert-Eq (($labels | ForEach-Object { $_.Offset }) -join ',') '0,10,19,29' 'labels are spread over the window'
Assert-Eq $labels[3].Day.ToString('yyyy-MM-dd') '2026-09-30' 'the last label is the last day'
Assert-Eq (@(Get-UsageTrendChartDayLabels -StartDay ([datetime]'2026-09-01') -Days 7 -Count 1)[0].Day.ToString('yyyy-MM-dd')) '2026-09-07' 'a single label is the last day'
Assert-Eq (@(Get-UsageTrendChartDayLabels -StartDay ([datetime]'2026-09-01') -Days 3 -Count 8).Count) 3 'the label count cannot exceed the window'
Assert-Eq (@(Get-UsageTrendChartDayLabels -StartDay ([datetime]'2026-09-01') -Days 0).Count) 0 'an empty window has no labels'

# ---------- 图例数值 ----------
Assert-Eq (Get-UsageTrendLatestPercent @((New-Point '2026-09-01' 10), (New-Point '2026-09-02' 25))) 25 'the latest value is the last sample'
Assert-Eq ($null -eq (Get-UsageTrendLatestPercent @())) 'True' 'an empty series has no latest value'
Assert-Eq ($null -eq (Get-UsageTrendLatestPercent $null)) 'True' 'a null series has no latest value'

# ---------- 绘图模型 ----------
$entries = @(
    @{ Id = 'grok'; Name = 'Grok a'; Series = @((New-Point '2026-09-01' 10), (New-Point '2026-09-03' 30)) }
    @{ Id = 'kimi'; Name = 'Kimi'; Series = @((New-Point '2026-08-01' 5)) }
)
$model = @(Get-UsageTrendChartModel -Entries $entries -StartDay ([datetime]'2026-09-01') -Days 7 -Width 120 -Height 60 -Pad 0)
Assert-Eq $model.Count 1 'series without samples in the window are skipped'
Assert-Eq $model[0].Id 'grok' 'the model keeps the entry id'
Assert-Eq $model[0].Name 'Grok a' 'the model keeps the display name'
Assert-Eq $model[0].Latest 30 'the model carries the latest percentage'
Assert-Eq $model[0].Points.Count 2 'the model carries the plotted points'
Assert-Eq (@(Get-UsageTrendChartModel -Entries @() -StartDay ([datetime]'2026-09-01') -Days 7 -Width 120 -Height 60).Count) 0 'no entries means an empty model'

# ---------- Demo 合成序列 ----------
$demo = @(New-UsageTrendDemoSeries -EndPct 42 -Days 30 -EndDay ([datetime]'2026-09-30'))
Assert-Eq $demo.Count 30 'the demo series covers every day'
Assert-Eq $demo[0].Day.ToString('yyyy-MM-dd') '2026-09-01' 'the demo series starts at the oldest day'
Assert-Eq $demo[29].Day.ToString('yyyy-MM-dd') '2026-09-30' 'the demo series ends today'
Assert-Eq $demo[29].Pct 42 'the demo series ends at the current percentage'
Assert-Eq (@($demo | Where-Object { $_.Pct -lt 0 -or $_.Pct -gt 100 }).Count) 0 'demo values stay inside the range'
$again = @(New-UsageTrendDemoSeries -EndPct 42 -Days 30 -EndDay ([datetime]'2026-09-30'))
Assert-Eq (($demo | ForEach-Object { $_.Pct }) -join ',') (($again | ForEach-Object { $_.Pct }) -join ',') 'the demo series is deterministic'
Assert-Eq (@(New-UsageTrendDemoSeries -EndPct 5 -Days 0).Count) 0 'a zero day demo series is empty'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
