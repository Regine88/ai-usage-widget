# Encoding: UTF-8 with BOM.
# WidgetLayout.ps1 - 卡片行高与窗体尺寸的纯函数计算。
#
# 设计像素以 96 DPI 为 1.0；主程序把 Form.DeviceDpi 换成 Scale 再传入。
# 不引用 WinForms，所以可以在没有窗口的情况下测 full / compact 两套尺寸。

function ConvertTo-WidgetLayoutName {
    param($Value, [string]$Default = 'full')
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('full', 'compact')) { return $text }
    return $Default
}

function ConvertTo-WidgetLayoutScale {
    param($Value, [double]$Default = 1.0)
    if (-not (Test-FiniteNumber $Value)) { return $Default }
    $scale = [double]$Value
    if ($scale -le 0 -or $scale -gt 10) { return $Default }
    return $scale
}

function Get-WidgetLayoutMetrics {
    param(
        $Scale = 1.0,
        $Layout = 'full',
        [bool]$ShowTrend = $true
    )
    $scale = ConvertTo-WidgetLayoutScale $Scale 1.0
    $layout = ConvertTo-WidgetLayoutName $Layout 'full'
    $px = {
        param([double]$Value)
        return [int][Math]::Round($Value * $scale)
    }

    if ($layout -eq 'compact') {
        $metrics = @{
            Layout     = 'compact'
            FormWidth  = (& $px 280)
            MarginX    = (& $px 16)
            ContentW   = (& $px 248)
            TopPad     = (& $px 8)
            RowH       = (& $px 38)
            BarInset   = (& $px 6)
            BottomPad  = (& $px 22)
            NameTop    = (& $px 2)
            NameW      = (& $px 172)
            NameH      = (& $px 16)
            PctW       = (& $px 76)
            PctH       = (& $px 18)
            BarTop     = (& $px 22)
            BarH       = (& $px 5)
            BarSeedW   = (& $px 4)
            DetailTop  = 0
            DetailH    = 0
            StampInset = (& $px 20)
            StampH     = (& $px 16)
            Radius     = (& $px 14)
            EdgeInset  = (& $px 24)
            TrendW     = (& $px 48)
            TrendH     = (& $px 14)
            TrendGap   = (& $px 8)
            TrendPad   = (& $px 4)
            FontName   = 8.0
            FontPct    = 11.0
            FontDetail = 7.5
        }
    } else {
        $metrics = @{
            Layout     = 'full'
            FormWidth  = (& $px 280)
            MarginX    = (& $px 16)
            ContentW   = (& $px 248)
            TopPad     = (& $px 14)
            RowH       = (& $px 74)
            BarInset   = (& $px 10)
            BottomPad  = (& $px 26)
            NameTop    = (& $px 4)
            NameW      = (& $px 172)
            NameH      = (& $px 18)
            PctW       = (& $px 76)
            PctH       = (& $px 26)
            BarTop     = (& $px 30)
            BarH       = (& $px 8)
            BarSeedW   = (& $px 6)
            DetailTop  = (& $px 44)
            DetailH    = (& $px 16)
            StampInset = (& $px 24)
            StampH     = (& $px 18)
            Radius     = (& $px 18)
            EdgeInset  = (& $px 24)
            TrendW     = (& $px 56)
            TrendH     = (& $px 20)
            TrendGap   = (& $px 8)
            TrendPad   = (& $px 6)
            FontName   = 9.0
            FontPct    = 16.0
            FontDetail = 8.5
        }
    }

    $trendSpace = if ($ShowTrend) { $metrics.TrendW + $metrics.TrendGap } else { 0 }
    $metrics.BarTrackW = [Math]::Max((& $px 80), ($metrics.ContentW - $trendSpace))
    $metrics.ShowTrend = [bool]$ShowTrend
    return $metrics
}

function Get-WidgetFormHeight {
    param($Metrics, [int]$RowCount)
    if (-not $Metrics) { $Metrics = Get-WidgetLayoutMetrics }
    $n = [Math]::Max(1, $RowCount)
    return $Metrics.TopPad + $n * $Metrics.RowH - $Metrics.BarInset + $Metrics.BottomPad
}
